package apigeeapi

import (
	v1alpha1 "github.com/devops-demo/apigee-api-operator/pkg/generated/informers/externalversions/apigeeapi/v1alpha1"
	internalinterfaces "github.com/devops-demo/apigee-api-operator/pkg/generated/informers/externalversions/internalinterfaces"
)

type Interface interface {
	V1alpha1() v1alpha1.ApigeeAPIInformer
}

type group struct {
	factory          internalinterfaces.SharedInformerFactory
	namespace        string
	tweakListOptions internalinterfaces.TweakListOptionsFunc
}

func New(f internalinterfaces.SharedInformerFactory, namespace string, tweakListOptions internalinterfaces.TweakListOptionsFunc) Interface {
	return &group{factory: f, namespace: namespace, tweakListOptions: tweakListOptions}
}

func (g *group) V1alpha1() v1alpha1.ApigeeAPIInformer {
	return v1alpha1.New(g.factory, g.namespace, g.tweakListOptions)
}
