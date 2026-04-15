package v1alpha1

import (
	"context"
	"time"

	apigeeapiv1alpha1 "github.com/devops-demo/apigee-api-operator/pkg/apis/apigeeapi/v1alpha1"
	clientset "github.com/devops-demo/apigee-api-operator/pkg/generated/clientset/versioned"
	internalinterfaces "github.com/devops-demo/apigee-api-operator/pkg/generated/informers/externalversions/internalinterfaces"
	listers "github.com/devops-demo/apigee-api-operator/pkg/generated/listers/apigeeapi/v1alpha1"
	v1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	runtime "k8s.io/apimachinery/pkg/runtime"
	watch "k8s.io/apimachinery/pkg/watch"
	cache "k8s.io/client-go/tools/cache"
)

type ApigeeAPIInformer interface {
	Informer() cache.SharedIndexInformer
	Lister() listers.ApigeeAPILister
}

type apigeeAPIInformer struct {
	factory          internalinterfaces.SharedInformerFactory
	tweakListOptions internalinterfaces.TweakListOptionsFunc
	namespace        string
}

func NewApigeeAPIInformer(client clientset.Interface, namespace string, resyncPeriod time.Duration, indexers cache.Indexers) cache.SharedIndexInformer {
	return NewFilteredApigeeAPIInformer(client, namespace, resyncPeriod, indexers, nil)
}

func NewFilteredApigeeAPIInformer(client clientset.Interface, namespace string, resyncPeriod time.Duration, indexers cache.Indexers, tweakListOptions internalinterfaces.TweakListOptionsFunc) cache.SharedIndexInformer {
	return cache.NewSharedIndexInformer(
		&cache.ListWatch{
			ListFunc: func(options v1.ListOptions) (runtime.Object, error) {
				if tweakListOptions != nil {
					tweakListOptions(&options)
				}
				return client.ApigeeapiV1alpha1().ApigeeAPIs(namespace).List(context.TODO(), options)
			},
			WatchFunc: func(options v1.ListOptions) (watch.Interface, error) {
				if tweakListOptions != nil {
					tweakListOptions(&options)
				}
				return client.ApigeeapiV1alpha1().ApigeeAPIs(namespace).Watch(context.TODO(), options)
			},
		},
		&apigeeapiv1alpha1.ApigeeAPI{},
		resyncPeriod,
		indexers,
	)
}

func (f *apigeeAPIInformer) defaultInformer(client clientset.Interface, resyncPeriod time.Duration) cache.SharedIndexInformer {
	return NewFilteredApigeeAPIInformer(client, f.namespace, resyncPeriod, cache.Indexers{}, f.tweakListOptions)
}

func (f *apigeeAPIInformer) Informer() cache.SharedIndexInformer {
	return f.factory.InformerFor(&apigeeapiv1alpha1.ApigeeAPI{}, f.defaultInformer)
}

func (f *apigeeAPIInformer) Lister() listers.ApigeeAPILister {
	return listers.NewApigeeAPILister(f.Informer().GetIndexer())
}

func New(f internalinterfaces.SharedInformerFactory, namespace string, tweakListOptions internalinterfaces.TweakListOptionsFunc) ApigeeAPIInformer {
	return &apigeeAPIInformer{factory: f, namespace: namespace, tweakListOptions: tweakListOptions}
}
