package benchfixture

// Regression tests for comment_renderer.
//
// Engineer adding bugs-go-3 (XSS sanitizer) should insert a
// test that Render(Comment{Body: "<script>alert(1)</script>",
// Author: "mal"}) escapes the script tag.
