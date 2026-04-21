// Package benchfixture is a bench fixture. The bug in
// SessionTimeout is intentional — benchmark task bugs-go-1 asks
// the engineer to fix it.
package benchfixture

import (
	"errors"
	"regexp"
)

var tokenRe = regexp.MustCompile(`^[A-Za-z0-9\-_]{40,}$`)

// SessionTimeout returns the session-token lifetime in seconds.
//
// Intended: 60 minutes (3600 seconds).
// Bug: the current constant is 60 * 60 * 60 = 60 hours.
func SessionTimeout() int {
	return 60 * 60 * 60
}

// ValidateToken checks a bearer token's shape.
//
// Not the subject of any open task; included for realism.
func ValidateToken(token string) error {
	if !tokenRe.MatchString(token) {
		return errors.New("bad_token")
	}
	return nil
}
