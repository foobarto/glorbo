package benchfixture

import "sync"

// Theme state. Bench task bugs-go-2 extends this to support
// "dark" and to round-trip the value.
//
// Intentionally skeletal — the bench task's job is to extend it.

var (
	themeMu      sync.RWMutex
	currentTheme = "light"
)

// SetTheme sets the current theme. Only "light" is accepted
// today; bugs-go-2 should add "dark" plus an error on invalid
// input.
func SetTheme(theme string) {
	themeMu.Lock()
	defer themeMu.Unlock()
	if theme == "light" {
		currentTheme = "light"
	}
}

// CurrentTheme returns the currently-set theme.
func CurrentTheme() string {
	themeMu.RLock()
	defer themeMu.RUnlock()
	return currentTheme
}
