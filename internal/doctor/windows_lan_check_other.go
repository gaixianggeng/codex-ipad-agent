//go:build !windows

package doctor

import "context"

func (c *Checker) windowsLANCheck(context.Context) Check {
	return Check{}
}
