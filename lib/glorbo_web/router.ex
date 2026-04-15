defmodule GlorboWeb.Router do
  use GlorboWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {GlorboWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/", GlorboWeb do
    pipe_through :browser

    get "/health", PageController, :health
  end

  # Other scopes may use custom stacks.
  # scope "/api", GlorboWeb do
  #   pipe_through :api
  # end
end
