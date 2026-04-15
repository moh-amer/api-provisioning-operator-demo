package internalinterfaces

import (
	"time"

	clientset "github.com/devops-demo/apigee-api-operator/pkg/generated/clientset/versioned"
	v1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	runtime "k8s.io/apimachinery/pkg/runtime"
	cache "k8s.io/client-go/tools/cache"
)

type NewInformerFunc func(clientset.Interface, time.Duration) cache.SharedIndexInformer

type TweakListOptionsFunc func(*v1.ListOptions)

type SharedInformerFactory interface {
	Start(stopCh <-chan struct{})
	InformerFor(obj runtime.Object, newFunc NewInformerFunc) cache.SharedIndexInformer
}
