defmodule GlorboWeb.SetupBannerTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias GlorboWeb.SetupBanner

  setup do
    keys = [
      {:glorbo, :dev_setup_banner},
      {:glorbo, :director_password_hash},
      {:glorbo, :dashboard_token},
      {:glorbo, GlorboWeb.Endpoint},
      {:phoenix, :serve_endpoints}
    ]

    previous = Enum.map(keys, fn {app, key} -> {app, key, Application.get_env(app, key)} end)

    on_exit(fn ->
      Enum.each(previous, fn {app, key, value} ->
        if is_nil(value),
          do: Application.delete_env(app, key),
          else: Application.put_env(app, key, value)
      end)
    end)

    :ok
  end

  test "ordinary application-starting Mix tasks do not print a setup credential" do
    Application.put_env(:glorbo, :dev_setup_banner, true)
    Application.put_env(:glorbo, :director_password_hash, nil)
    Application.put_env(:phoenix, :serve_endpoints, false)
    Application.put_env(:glorbo, GlorboWeb.Endpoint, server: false)

    assert capture_io(fn -> assert :ignore = SetupBanner.start_link() end) == ""
  end

  test "a real Phoenix development server gets the first-run banner" do
    Application.put_env(:glorbo, :dev_setup_banner, true)
    Application.put_env(:glorbo, :director_password_hash, nil)
    Application.put_env(:glorbo, :dashboard_token, "banner-test-token")
    Application.put_env(:phoenix, :serve_endpoints, true)
    Application.put_env(:glorbo, GlorboWeb.Endpoint, http: [port: 4321])

    output = capture_io(fn -> assert :ignore = SetupBanner.start_link() end)
    assert output =~ "http://127.0.0.1:4321/setup?token=banner-test-token"
  end

  test "configured nodes never reprint the token" do
    Application.put_env(:glorbo, :dev_setup_banner, true)
    Application.put_env(:glorbo, :director_password_hash, "configured-hash")
    Application.put_env(:phoenix, :serve_endpoints, true)

    assert capture_io(fn -> assert :ignore = SetupBanner.start_link() end) == ""
  end
end
