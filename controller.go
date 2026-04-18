package main

import (
	"context"
	"fmt"
	"time"

	"golang.org/x/time/rate"

	"k8s.io/apimachinery/pkg/api/errors"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	utilruntime "k8s.io/apimachinery/pkg/util/runtime"
	"k8s.io/apimachinery/pkg/util/wait"
	"k8s.io/client-go/kubernetes"
	"k8s.io/client-go/kubernetes/scheme"
	typedcorev1 "k8s.io/client-go/kubernetes/typed/core/v1"
	"k8s.io/client-go/tools/cache"
	"k8s.io/client-go/tools/record"
	"k8s.io/client-go/util/retry"
	"k8s.io/client-go/util/workqueue"
	"k8s.io/klog/v2"

	corev1 "k8s.io/api/core/v1"

	apigeeapiv1alpha1 "github.com/devops-demo/apigee-api-operator/pkg/apis/apigeeapi/v1alpha1"
	"github.com/devops-demo/apigee-api-operator/pkg/apigee"
	clientset "github.com/devops-demo/apigee-api-operator/pkg/generated/clientset/versioned"
	samplescheme "github.com/devops-demo/apigee-api-operator/pkg/generated/clientset/versioned/scheme"
	informers "github.com/devops-demo/apigee-api-operator/pkg/generated/informers/externalversions/apigeeapi/v1alpha1"
	listers "github.com/devops-demo/apigee-api-operator/pkg/generated/listers/apigeeapi/v1alpha1"
)

const controllerAgentName = "apigeeapi-controller"

// FinalizerName is the finalizer we add to ApigeeAPI resources.
//
// KEY ARCHITECTURAL DIFFERENCE FROM STATICSITE OPERATOR:
// StaticSite uses OwnerReferences for cleanup (K8s GC deletes children automatically).
// ApigeeAPI uses Finalizers because the "children" are EXTERNAL Apigee resources
// that K8s GC knows nothing about. We must explicitly undeploy and delete the proxy
// on Apigee before allowing the CR to be deleted.
const FinalizerName = "apigeeapi.example.com/finalizer"

const (
	SuccessSynced     = "Synced"
	MessageSynced     = "ApigeeAPI synced successfully"
	ErrApigee         = "ErrApigee"
	DriftDetected     = "DriftDetected"
	FieldManager      = controllerAgentName
)

// Controller manages ApigeeAPI resources.
// Same Informer → Workqueue → syncHandler pattern as sample-controller,
// but instead of creating K8s child resources, it calls the Apigee REST API.
type Controller struct {
	kubeclientset     kubernetes.Interface
	apigeeapiClientset clientset.Interface

	// Only ONE lister needed — we don't watch K8s children (no Deployments, Services, etc.)
	apigeeapisLister listers.ApigeeAPILister
	apigeeapisSynced cache.InformerSynced

	// Apigee REST API client — this is the "external world" we manage
	apigeeClient *apigee.Client

	workqueue workqueue.TypedRateLimitingInterface[cache.ObjectName]
	recorder  record.EventRecorder
}

// NewController returns a new ApigeeAPI controller.
func NewController(
	ctx context.Context,
	kubeclientset kubernetes.Interface,
	apigeeapiClientset clientset.Interface,
	apigeeAPIInformer informers.ApigeeAPIInformer,
	apigeeClient *apigee.Client,
) *Controller {
	logger := klog.FromContext(ctx)

	utilruntime.Must(samplescheme.AddToScheme(scheme.Scheme))
	logger.V(4).Info("Creating event broadcaster")

	eventBroadcaster := record.NewBroadcaster(record.WithContext(ctx))
	eventBroadcaster.StartStructuredLogging(0)
	eventBroadcaster.StartRecordingToSink(&typedcorev1.EventSinkImpl{Interface: kubeclientset.CoreV1().Events("")})
	recorder := eventBroadcaster.NewRecorder(scheme.Scheme, corev1.EventSource{Component: controllerAgentName})

	ratelimiter := workqueue.NewTypedMaxOfRateLimiter(
		workqueue.NewTypedItemExponentialFailureRateLimiter[cache.ObjectName](5*time.Millisecond, 1000*time.Second),
		&workqueue.TypedBucketRateLimiter[cache.ObjectName]{Limiter: rate.NewLimiter(rate.Limit(50), 300)},
	)

	controller := &Controller{
		kubeclientset:      kubeclientset,
		apigeeapiClientset: apigeeapiClientset,
		apigeeapisLister:   apigeeAPIInformer.Lister(),
		apigeeapisSynced:   apigeeAPIInformer.Informer().HasSynced,
		apigeeClient:       apigeeClient,
		workqueue:          workqueue.NewTypedRateLimitingQueue(ratelimiter),
		recorder:           recorder,
	}

	logger.Info("Setting up event handlers")

	// Watch ApigeeAPI resources.
	// KEY FIX: UpdateFunc only re-queues if the Spec actually changed.
	// metadata.generation increments ONLY on spec changes, NOT on status updates.
	// Without this filter, every updateStatus() call would re-queue → infinite loop.
	apigeeAPIInformer.Informer().AddEventHandler(cache.ResourceEventHandlerFuncs{
		AddFunc: controller.enqueueApigeeAPI,
		UpdateFunc: func(old, new interface{}) {
			oldAPI := old.(*apigeeapiv1alpha1.ApigeeAPI)
			newAPI := new.(*apigeeapiv1alpha1.ApigeeAPI)
			// Periodic resync: informer re-delivers the same cached object
			// (identical ResourceVersion). Let these through so syncHandler
			// can verify the proxy still exists on Apigee (drift detection).
			// Status-update events have different ResourceVersions and same
			// Generation, so they remain filtered — no infinite loop.
			isResync := oldAPI.ResourceVersion == newAPI.ResourceVersion
			finalizerAdded := !containsFinalizer(oldAPI, FinalizerName) && containsFinalizer(newAPI, FinalizerName)
			if oldAPI.Generation != newAPI.Generation || newAPI.DeletionTimestamp != nil || finalizerAdded || isResync {
				controller.enqueueApigeeAPI(new)
			}
		},
	})

	return controller
}

// Run starts the controller.
func (c *Controller) Run(ctx context.Context, workers int) error {
	defer utilruntime.HandleCrash()
	defer c.workqueue.ShutDown()
	logger := klog.FromContext(ctx)

	logger.Info("Starting ApigeeAPI controller")
	logger.Info("Waiting for informer caches to sync")

	if ok := cache.WaitForCacheSync(ctx.Done(), c.apigeeapisSynced); !ok {
		return fmt.Errorf("failed to wait for caches to sync")
	}

	logger.Info("Starting workers", "count", workers)
	for i := 0; i < workers; i++ {
		go wait.UntilWithContext(ctx, c.runWorker, time.Second)
	}

	logger.Info("Started workers")
	<-ctx.Done()
	logger.Info("Shutting down workers")
	return nil
}

func (c *Controller) runWorker(ctx context.Context) {
	for c.processNextWorkItem(ctx) {
	}
}

func (c *Controller) processNextWorkItem(ctx context.Context) bool {
	objRef, shutdown := c.workqueue.Get()
	logger := klog.FromContext(ctx)

	if shutdown {
		return false
	}
	defer c.workqueue.Done(objRef)

	err := c.syncHandler(ctx, objRef)
	if err == nil {
		c.workqueue.Forget(objRef)
		logger.Info("Successfully synced", "objectName", objRef)
		return true
	}

	utilruntime.HandleErrorWithContext(ctx, err, "Error syncing; requeuing for later retry", "objectReference", objRef)
	c.workqueue.AddRateLimited(objRef)
	return true
}

// syncHandler — THE HEART of the Apigee operator.
//
// KEY DIFFERENCES from StaticSite operator's syncHandler:
//   1. No K8s child resources — we call Apigee REST API instead
//   2. Uses Finalizers for cleanup (not OwnerReferences)
//   3. Phase-based status tracking (Pending → Creating → Deploying → Ready)
func (c *Controller) syncHandler(ctx context.Context, objectRef cache.ObjectName) error {
	logger := klog.LoggerWithValues(klog.FromContext(ctx), "objectRef", objectRef)

	// ──── Step 1: Get the ApigeeAPI from local cache ────
	api, err := c.apigeeapisLister.ApigeeAPIs(objectRef.Namespace).Get(objectRef.Name)
	if err != nil {
		if errors.IsNotFound(err) {
			logger.Info("ApigeeAPI deleted from cache, nothing to do")
			return nil
		}
		return err
	}

	proxyName := api.Spec.ProxyName
	if proxyName == "" {
		proxyName = api.Name
	}

	// ──── Step 2: Handle Deletion (Finalizer pattern) ────
	// If the CR is being deleted and has our finalizer, clean up Apigee first
	if api.DeletionTimestamp != nil {
		if containsFinalizer(api, FinalizerName) {
			logger.Info("Handling deletion — cleaning up Apigee resources", "proxyName", proxyName)

			// ① Save revision from cache NOW, before updateStatus can clear it.
			//    Bug: updateStatus(revision=0) clears proxyRevision in the API server.
			//    On the next retry (after restart) the cache has revision=0, undeploy
			//    is skipped, DeleteProxy returns FAILED_PRECONDITION because the proxy
			//    is still deployed. Fix: save + preserve the revision across retries.
			revisionToUndeploy := api.Status.ProxyRevision

			// ② Update status — pass the saved revision so it survives restarts.
			if err := c.updateStatus(ctx, api, "Deleting", false, revisionToUndeploy, "", "Cleaning up Apigee resources...", api.Generation); err != nil {
				return err
			}

			// ③ Undeploy from environment (required before DeleteProxy will succeed).
			if revisionToUndeploy > 0 {
				if err := c.apigeeClient.UndeployRevision(ctx, api.Spec.Organization, api.Spec.Environment, proxyName, revisionToUndeploy); err != nil {
					logger.Error(err, "Failed to undeploy (may already be undeployed)", "revision", revisionToUndeploy)
					// Continue — we still want to try deleting the proxy
				}
			} else {
				logger.Info("No tracked revision to undeploy — attempting delete directly", "proxyName", proxyName)
			}

			// ④ Delete the proxy bundle from Apigee
			if err := c.apigeeClient.DeleteProxy(ctx, api.Spec.Organization, proxyName); err != nil {
				logger.Error(err, "Failed to delete proxy from Apigee")
				c.recorder.Event(api, corev1.EventTypeWarning, ErrApigee, fmt.Sprintf("Failed to delete proxy: %v", err))
				return err
			}

			// ⑤ Remove finalizer — allows K8s to complete deletion
			apiCopy := api.DeepCopy()
			apiCopy.Finalizers = removeFinalizer(apiCopy, FinalizerName)
			_, err := c.apigeeapiClientset.ApigeeapiV1alpha1().ApigeeAPIs(api.Namespace).Update(ctx, apiCopy, metav1.UpdateOptions{FieldManager: FieldManager})
			if err != nil {
				return err
			}

			logger.Info("Successfully cleaned up Apigee resources", "proxyName", proxyName)
			c.recorder.Event(api, corev1.EventTypeNormal, SuccessSynced, "Apigee proxy deleted and undeployed")
		}
		return nil
	}

	// ──── Step 3: Idempotency guard + Drift detection ────
	// If we already successfully reconciled this spec version, verify the proxy
	// still exists on Apigee before skipping. If someone deleted it externally
	// (e.g. via Apigee console or gcloud), we fall through to re-create it.
	//
	// Infinite-loop safety:
	//   - UpdateFunc filters status-update events (different ResourceVersion, same Generation)
	//   - Only periodic resyncs (same ResourceVersion) reach here
	//   - After re-creation, status is set to Ready + ObservedGeneration → next resync
	//     finds proxy exists → skip. No loop.
	if api.Status.Phase == "Ready" &&
		api.Status.Deployed &&
		api.Status.ObservedGeneration == api.Generation {
		// Lightweight drift check: does the proxy still exist on Apigee?
		existing, err := c.apigeeClient.GetProxy(ctx, api.Spec.Organization, proxyName)
		if err != nil {
			logger.Error(err, "Drift check failed — cannot reach Apigee API, will retry")
			return err
		}
		if existing != nil {
			// Proxy exists — no drift, skip reconciliation
			logger.V(4).Info("Drift check passed — proxy exists on Apigee, skipping",
				"generation", api.Generation, "proxyRevision", api.Status.ProxyRevision)
			return nil
		}
		// DRIFT DETECTED: proxy was deleted externally — fall through to re-create
		logger.Info("DRIFT DETECTED: proxy missing on Apigee — re-reconciling",
			"proxyName", proxyName, "generation", api.Generation)
		c.recorder.Event(api, corev1.EventTypeWarning, DriftDetected,
			fmt.Sprintf("Proxy %q was deleted from Apigee externally — re-creating", proxyName))
	}

	// ──── Step 4: Ensure Finalizer is present ────
	// Uses RetryOnConflict: if another controller updated the object between
	// our cache read and our write, retry with the freshest version.
	if !containsFinalizer(api, FinalizerName) {
		logger.Info("Adding finalizer")
		err := retry.RetryOnConflict(retry.DefaultRetry, func() error {
			// Always re-fetch the LATEST version from API server before writing
			latest, err := c.liveGet(ctx, api.Namespace, api.Name)
			if err != nil {
				return err
			}
			latestCopy := latest.DeepCopy()
			latestCopy.Finalizers = append(latestCopy.Finalizers, FinalizerName)
			_, err = c.apigeeapiClientset.ApigeeapiV1alpha1().ApigeeAPIs(api.Namespace).Update(ctx, latestCopy, metav1.UpdateOptions{FieldManager: FieldManager})
			return err
		})
		if err != nil {
			return err
		}
		return nil // Will be re-queued due to the update
	}

	// ──── Step 4: Check if proxy exists on Apigee ────
	existingProxy, err := c.apigeeClient.GetProxy(ctx, api.Spec.Organization, proxyName)
	if err != nil {
		c.recorder.Event(api, corev1.EventTypeWarning, ErrApigee, fmt.Sprintf("Failed to check proxy: %v", err))
		return c.updateStatus(ctx, api, "Error", false, 0, "", fmt.Sprintf("Failed to check proxy: %v", err), api.Generation)
	}

	// ──── Step 5: Create or Update the proxy ────
	if err := c.updateStatus(ctx, api, "Creating", false, 0, "", "Creating/updating API proxy...", api.Generation); err != nil {
		logger.Error(err, "Failed to update status to Creating")
	}

	revision, err := c.apigeeClient.CreateProxyWithBundle(ctx,
		api.Spec.Organization, proxyName, api.Spec.BasePath, api.Spec.TargetURL, api.Spec.Description,
		api.Spec.Policies)
	if err != nil {
		c.recorder.Event(api, corev1.EventTypeWarning, ErrApigee, fmt.Sprintf("Failed to create proxy: %v", err))
		return c.updateStatus(ctx, api, "Error", false, 0, "", fmt.Sprintf("Failed to create proxy: %v", err), api.Generation)
	}

	if existingProxy != nil {
		logger.Info("Updated existing proxy", "proxyName", proxyName, "newRevision", revision)
	} else {
		logger.Info("Created new proxy", "proxyName", proxyName, "revision", revision)
	}

	// ──── Step 6: Deploy revision to environment ────
	if err := c.updateStatus(ctx, api, "Deploying", false, revision, "", fmt.Sprintf("Deploying revision %d to %s...", revision, api.Spec.Environment), api.Generation); err != nil {
		logger.Error(err, "Failed to update status to Deploying")
	}

	if err := c.apigeeClient.DeployRevision(ctx, api.Spec.Organization, api.Spec.Environment, proxyName, revision); err != nil {
		c.recorder.Event(api, corev1.EventTypeWarning, ErrApigee, fmt.Sprintf("Failed to deploy: %v", err))
		return c.updateStatus(ctx, api, "Error", false, revision, "", fmt.Sprintf("Failed to deploy revision %d: %v", revision, err), api.Generation)
	}

	// ──── Step 7: Resolve the real public URL ────
	// Apigee X hostnames are defined per Environment Group — not derivable from the
	// org name. We must query the envgroups API to get the real hostname.
	// Fallback to the legacy guessed format so we never block on URL resolution.
	hostname, err := c.apigeeClient.GetEnvironmentHostname(ctx, api.Spec.Organization, api.Spec.Environment)
	var publicURL string
	if err != nil {
		logger.V(2).Info("Could not resolve envgroup hostname, using fallback URL",
			"err", err, "org", api.Spec.Organization, "env", api.Spec.Environment)
		// Fallback: known working format for some Apigee orgs
		hostname = fmt.Sprintf("%s-%s.apigee.net", api.Spec.Organization, api.Spec.Environment)
	}
	publicURL = fmt.Sprintf("https://%s%s", hostname, api.Spec.BasePath)
	logger.Info("Resolved public URL", "url", publicURL)

	if err := c.updateStatus(ctx, api, "Ready", true, revision, publicURL, fmt.Sprintf("API proxy deployed (rev %d)", revision), api.Generation); err != nil {
		return err
	}

	c.recorder.Event(api, corev1.EventTypeNormal, SuccessSynced, MessageSynced)
	return nil
}

// liveGet fetches the LATEST version of an ApigeeAPI directly from the API server
// (bypassing the local informer cache). This is critical before any write operation
// to avoid "object has been modified" resource version conflicts.
func (c *Controller) liveGet(ctx context.Context, namespace, name string) (*apigeeapiv1alpha1.ApigeeAPI, error) {
	return c.apigeeapiClientset.ApigeeapiV1alpha1().ApigeeAPIs(namespace).Get(ctx, name, metav1.GetOptions{})
}

// updateStatus re-fetches the latest version from the API server then updates status.
// Wrapped in RetryOnConflict so concurrent modifications don't fail the sync.
func (c *Controller) updateStatus(ctx context.Context, api *apigeeapiv1alpha1.ApigeeAPI, phase string, deployed bool, revision int, publicURL, message string, reconciledGeneration int64) error {
	return retry.RetryOnConflict(retry.DefaultRetry, func() error {
		// Re-fetch fresh copy to get current resourceVersion
		latest, err := c.liveGet(ctx, api.Namespace, api.Name)
		if err != nil {
			if errors.IsNotFound(err) {
				return nil // Object gone -- nothing to update
			}
			return err
		}
		latestCopy := latest.DeepCopy()
		latestCopy.Status.Phase = phase
		latestCopy.Status.Deployed = deployed
		latestCopy.Status.ProxyRevision = revision
		latestCopy.Status.Message = message
		if publicURL != "" {
			latestCopy.Status.PublicURL = publicURL
		}
		// Record the generation we ACTUALLY reconciled, not the live generation.
		// This prevents a race where a new spec change arrives mid-reconciliation:
		// without this, we'd stamp obsGen=newer-gen but only applied older-gen data.
		if phase == "Ready" {
			latestCopy.Status.ObservedGeneration = reconciledGeneration
		}
		_, err = c.apigeeapiClientset.ApigeeapiV1alpha1().ApigeeAPIs(api.Namespace).UpdateStatus(ctx, latestCopy, metav1.UpdateOptions{FieldManager: FieldManager})
		return err
	})
}

func (c *Controller) enqueueApigeeAPI(obj interface{}) {
	if objectRef, err := cache.ObjectToName(obj); err != nil {
		utilruntime.HandleError(err)
	} else {
		c.workqueue.Add(objectRef)
	}
}

// ──── Finalizer Helpers ────
// These are needed because Apigee resources are EXTERNAL to Kubernetes.
// Unlike OwnerReferences (which let K8s GC handle cleanup automatically),
// Finalizers require us to explicitly clean up before allowing deletion.

func containsFinalizer(api *apigeeapiv1alpha1.ApigeeAPI, finalizer string) bool {
	for _, f := range api.Finalizers {
		if f == finalizer {
			return true
		}
	}
	return false
}

func removeFinalizer(api *apigeeapiv1alpha1.ApigeeAPI, finalizer string) []string {
	var result []string
	for _, f := range api.Finalizers {
		if f != finalizer {
			result = append(result, f)
		}
	}
	return result
}
