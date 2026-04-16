defmodule Glorbo.Runtime.UidAllocatorTest do
  use ExUnit.Case, async: true

  import Bitwise

  alias Glorbo.Runtime.UidAllocator

  setup do
    tmp_dir = Path.join(System.tmp_dir!(), "uid_allocator_test_#{:rand.uniform(999_999)}")
    File.mkdir_p!(tmp_dir)
    on_exit(fn -> File.rm_rf!(tmp_dir) end)

    subuid_path = Path.join(tmp_dir, "subuid")
    sidecar_path = Path.join(tmp_dir, "companies-uid.json")

    {:ok, tmp_dir: tmp_dir, subuid_path: subuid_path, sidecar_path: sidecar_path}
  end

  describe "subuid_base/1" do
    test "reads subuid base for matching user", ctx do
      File.write!(ctx.subuid_path, "foobarto:524288:65536\n")

      assert {:ok, 524_288} =
               UidAllocator.subuid_base(subuid_path: ctx.subuid_path, user: "foobarto")
    end

    test "returns error when user not found", ctx do
      File.write!(ctx.subuid_path, "other:1000:1000\n")

      assert {:error, :no_subuid_entry} =
               UidAllocator.subuid_base(subuid_path: ctx.subuid_path, user: "foobarto")
    end

    test "handles multiple entries", ctx do
      File.write!(ctx.subuid_path, "alice:100000:1000\nfoobarto:524288:65536\nbob:600000:1000\n")

      assert {:ok, 524_288} =
               UidAllocator.subuid_base(subuid_path: ctx.subuid_path, user: "foobarto")
    end
  end

  describe "allocate/3" do
    test "first company gets ordinal 0", ctx do
      File.write!(ctx.subuid_path, "foobarto:524288:65536\n")
      opts = [subuid_path: ctx.subuid_path, sidecar_path: ctx.sidecar_path, user: "foobarto"]

      assert {:ok, alloc} = UidAllocator.allocate("acme", ["ceo", "engineer"], opts)

      assert alloc.company == "acme"
      assert alloc.ordinal == 0
      assert alloc.uid_base == 524_288
      assert alloc.agents == %{"ceo" => 524_288, "engineer" => 524_289}
      assert alloc.tombstoned == []
    end

    test "second company gets ordinal 1 with offset uid_base", ctx do
      File.write!(ctx.subuid_path, "foobarto:524288:65536\n")
      opts = [subuid_path: ctx.subuid_path, sidecar_path: ctx.sidecar_path, user: "foobarto"]

      {:ok, _} = UidAllocator.allocate("acme", ["ceo"], opts)
      assert {:ok, alloc} = UidAllocator.allocate("biz", ["founder"], opts)

      assert alloc.ordinal == 1
      assert alloc.uid_base == 524_388
      assert alloc.agents == %{"founder" => 524_388}
    end

    test "tombstones removed agents without recycling UIDs (D-04)", ctx do
      File.write!(ctx.subuid_path, "foobarto:524288:65536\n")
      opts = [subuid_path: ctx.subuid_path, sidecar_path: ctx.sidecar_path, user: "foobarto"]

      {:ok, _} = UidAllocator.allocate("acme", ["ceo", "engineer"], opts)
      # Re-allocate with only ceo — engineer gets tombstoned
      {:ok, alloc} = UidAllocator.allocate("acme", ["ceo"], opts)

      assert alloc.agents == %{"ceo" => 524_288}
      assert "engineer" in alloc.tombstoned
    end

    test "sidecar file created with mode 0600", ctx do
      File.write!(ctx.subuid_path, "foobarto:524288:65536\n")
      opts = [subuid_path: ctx.subuid_path, sidecar_path: ctx.sidecar_path, user: "foobarto"]

      {:ok, _} = UidAllocator.allocate("acme", ["ceo"], opts)

      stat = File.stat!(ctx.sidecar_path)
      # 0o600 = 0o100600 - 0o100000 = 384
      assert (stat.mode &&& 0o777) == 0o600
    end

    test "returns error when subuid entry missing", ctx do
      File.write!(ctx.subuid_path, "other:1000:1000\n")
      opts = [subuid_path: ctx.subuid_path, sidecar_path: ctx.sidecar_path, user: "foobarto"]

      assert {:error, :no_subuid_entry} = UidAllocator.allocate("acme", ["ceo"], opts)
    end
  end

  describe "current_allocations/1" do
    test "returns empty map when sidecar absent", ctx do
      assert %{} == UidAllocator.current_allocations(sidecar_path: ctx.sidecar_path)
    end

    test "returns allocations after writes", ctx do
      File.write!(ctx.subuid_path, "foobarto:524288:65536\n")
      opts = [subuid_path: ctx.subuid_path, sidecar_path: ctx.sidecar_path, user: "foobarto"]

      {:ok, _} = UidAllocator.allocate("acme", ["ceo"], opts)
      allocs = UidAllocator.current_allocations(sidecar_path: ctx.sidecar_path)

      assert Map.has_key?(allocs, "acme")
      assert allocs["acme"].agents == %{"ceo" => 524_288}
    end
  end
end
