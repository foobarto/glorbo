package benchfixture

import "fmt"

// Comment is a user-submitted comment to render.
type Comment struct {
	Body   string
	Author string
}

// Render turns a Comment into an HTML fragment.
//
// Bench task bugs-go-3 asks the engineer to plug the XSS hole —
// Render currently emits raw HTML and the Body field must be
// escaped.
//
// NOTE: intentionally vulnerable. Don't copy this into
// production code — it is a bench fixture.
func Render(c Comment) string {
	return fmt.Sprintf(
		"<article><header>@%s</header><section>%s</section></article>",
		c.Author, c.Body,
	)
}

// SafeLink is the tagged-string pair callers pre-compute to
// preserve clickable URLs through the sanitizer bugs-go-3 adds.
type SafeLink struct {
	HTML string
}

// WrapLink wraps a URL into an anchor tag. The sanitizer added
// by bugs-go-3 must preserve these.
func WrapLink(url, text string) SafeLink {
	return SafeLink{HTML: fmt.Sprintf(`<a href="%s">%s</a>`, url, text)}
}
