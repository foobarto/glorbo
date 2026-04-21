defmodule BenchFixture.CommentRenderer do
  @moduledoc """
  Renders user comments to HTML. Bench task bugs-3 asks the
  engineer to plug the XSS hole — `render/1` currently emits raw
  HTML and the task body must be escaped.

  NOTE: intentionally vulnerable. Don't copy this module into
  production code — it's a bench fixture.
  """

  @doc """
  Render a comment map (`%{body: binary, author: binary}`) to
  HTML. Current implementation passes `body` through raw.
  """
  def render(%{body: body, author: author}) do
    "<article><header>@#{author}</header><section>#{body}</section></article>"
  end

  @doc """
  Wrap a URL into an `<a href>` link. Callers pre-compute this;
  the sanitizer added by bugs-3 must preserve these links.
  """
  def wrap_link(url, text) when is_binary(url) and is_binary(text) do
    {:safe, ~s(<a href="#{url}">#{text}</a>)}
  end
end
