package v1alpha1

import (
	apigeeapiv1alpha1 "github.com/devops-demo/apigee-api-operator/pkg/apis/apigeeapi/v1alpha1"
	"k8s.io/apimachinery/pkg/api/errors"
	"k8s.io/apimachinery/pkg/labels"
	"k8s.io/client-go/tools/cache"
)

type ApigeeAPILister interface {
	List(selector labels.Selector) (ret []*apigeeapiv1alpha1.ApigeeAPI, err error)
	ApigeeAPIs(namespace string) ApigeeAPINamespaceLister
}

type apigeeAPILister struct {
	indexer cache.Indexer
}

func NewApigeeAPILister(indexer cache.Indexer) ApigeeAPILister {
	return &apigeeAPILister{indexer: indexer}
}

func (s *apigeeAPILister) List(selector labels.Selector) (ret []*apigeeapiv1alpha1.ApigeeAPI, err error) {
	err = cache.ListAll(s.indexer, selector, func(m interface{}) {
		ret = append(ret, m.(*apigeeapiv1alpha1.ApigeeAPI))
	})
	return ret, err
}

func (s *apigeeAPILister) ApigeeAPIs(namespace string) ApigeeAPINamespaceLister {
	return apigeeAPINamespaceLister{indexer: s.indexer, namespace: namespace}
}

type ApigeeAPINamespaceLister interface {
	List(selector labels.Selector) (ret []*apigeeapiv1alpha1.ApigeeAPI, err error)
	Get(name string) (*apigeeapiv1alpha1.ApigeeAPI, error)
}

type apigeeAPINamespaceLister struct {
	indexer   cache.Indexer
	namespace string
}

func (s apigeeAPINamespaceLister) List(selector labels.Selector) (ret []*apigeeapiv1alpha1.ApigeeAPI, err error) {
	err = cache.ListAllByNamespace(s.indexer, s.namespace, selector, func(m interface{}) {
		ret = append(ret, m.(*apigeeapiv1alpha1.ApigeeAPI))
	})
	return ret, err
}

func (s apigeeAPINamespaceLister) Get(name string) (*apigeeapiv1alpha1.ApigeeAPI, error) {
	obj, exists, err := s.indexer.GetByKey(s.namespace + "/" + name)
	if err != nil {
		return nil, err
	}
	if !exists {
		return nil, errors.NewNotFound(apigeeapiv1alpha1.Resource("apigeeapi"), name)
	}
	return obj.(*apigeeapiv1alpha1.ApigeeAPI), nil
}
