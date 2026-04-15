package main

import (
	"flag"
	"time"

	"k8s.io/client-go/kubernetes"
	"k8s.io/client-go/tools/clientcmd"
	"k8s.io/klog/v2"

	"github.com/devops-demo/apigee-api-operator/pkg/apigee"
	clientset "github.com/devops-demo/apigee-api-operator/pkg/generated/clientset/versioned"
	informers "github.com/devops-demo/apigee-api-operator/pkg/generated/informers/externalversions"
	"github.com/devops-demo/apigee-api-operator/pkg/signals"
)

var (
	masterURL  string
	kubeconfig string
)

func main() {
	klog.InitFlags(nil)
	flag.Parse()

	ctx := signals.SetupSignalHandler()
	logger := klog.FromContext(ctx)

	// 1️⃣  Build kubeconfig
	cfg, err := clientcmd.BuildConfigFromFlags(masterURL, kubeconfig)
	if err != nil {
		logger.Error(err, "Error building kubeconfig")
		klog.FlushAndExit(klog.ExitFlushTimeout, 1)
	}

	// 2️⃣  TWO Kubernetes clients (same pattern as sample-controller)
	kubeClient, err := kubernetes.NewForConfig(cfg)
	if err != nil {
		logger.Error(err, "Error building kubernetes clientset")
		klog.FlushAndExit(klog.ExitFlushTimeout, 1)
	}

	apigeeapiClient, err := clientset.NewForConfig(cfg)
	if err != nil {
		logger.Error(err, "Error building apigeeapi clientset")
		klog.FlushAndExit(klog.ExitFlushTimeout, 1)
	}

	// 3️⃣  PLUS an Apigee REST API client (Google Cloud ADC)
	//     This is the "external world" client — not present in sample-controller
	apigeeClient, err := apigee.NewClient(ctx)
	if err != nil {
		logger.Error(err, "Error creating Apigee client (check GOOGLE_APPLICATION_CREDENTIALS)")
		klog.FlushAndExit(klog.ExitFlushTimeout, 1)
	}

	// 4️⃣  Only ONE informer factory for our CRD
	//     (No kubeInformerFactory needed — we don't watch K8s child resources)
	apigeeapiInformerFactory := informers.NewSharedInformerFactory(apigeeapiClient, 30*time.Second)

	// 5️⃣  Wire the controller
	controller := NewController(ctx, kubeClient, apigeeapiClient,
		apigeeapiInformerFactory.Apigeeapi().V1alpha1(), // Watch ApigeeAPI CRD
		apigeeClient, // Apigee REST client
	)

	// 6️⃣  Start informers + Run
	apigeeapiInformerFactory.Start(ctx.Done())

	if err = controller.Run(ctx, 2); err != nil {
		logger.Error(err, "Error running controller")
		klog.FlushAndExit(klog.ExitFlushTimeout, 1)
	}
}

func init() {
	flag.StringVar(&kubeconfig, "kubeconfig", "", "Path to a kubeconfig. Only required if out-of-cluster.")
	flag.StringVar(&masterURL, "master", "", "The address of the Kubernetes API server. Overrides any value in kubeconfig. Only required if out-of-cluster.")
}
