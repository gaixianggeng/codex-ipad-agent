//go:build !windows

package main

func prepareManagedServeRuntime(bool) (func(), error) {
	return nil, nil
}
