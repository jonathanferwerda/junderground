defmodule Junderground.AdmissionTest do
  use ExUnit.Case, async: false

  alias Junderground.{Admission, Keys}

  setup do
    dir = Path.join(System.tmp_dir!(), "jg-adm-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)

    {admin_pub, _admin_priv} = Keys.generate()
    Application.put_env(:junderground, :admin_keys, [admin_pub])

    start_supervised!({Admission, data_dir: dir})

    on_exit(fn ->
      Application.put_env(:junderground, :admin_keys, [])
      File.rm_rf(dir)
    end)

    {pub, _priv} = Keys.generate()
    %{pub: pub, admin_pub: admin_pub}
  end

  test "a normal crest is pending; an administrator crest is approved", %{
    pub: pub,
    admin_pub: admin_pub
  } do
    assert {:ok, %{"status" => "pending"}} = Admission.pending("alpha", pub)
    assert {:ok, %{"status" => "approved"}} = Admission.pending("adminhouse", admin_pub)
  end

  test "pending is idempotent and never resets a decision", %{pub: pub} do
    assert {:ok, _} = Admission.pending("alpha", pub)
    assert {:ok, _} = Admission.decide("alpha", "approved", "agent", "checked", 0)
    assert {:ok, %{"status" => "approved"}} = Admission.pending("alpha", pub)
  end

  test "probation can join and speak, but cannot open rooms", %{pub: pub} do
    {:ok, _} = Admission.pending("alpha", pub)
    {:ok, _} = Admission.decide("alpha", "probation", "agent", "new house", 4_000_000_000)

    assert Admission.may_grant?("alpha")
    assert Admission.may_write?("alpha")
    refute Admission.may_create_room?("alpha")
    assert Admission.probation?("alpha")
  end

  test "a suspended house is stopped everywhere", %{pub: pub} do
    {:ok, _} = Admission.pending("alpha", pub)
    {:ok, _} = Admission.decide("alpha", "suspended", "agent", "reports", 0)

    refute Admission.may_grant?("alpha")
    refute Admission.may_write?("alpha")
    refute Admission.may_create_room?("alpha")
  end

  test "the queue and the audit log remember the decisions", %{pub: pub} do
    {:ok, _} = Admission.pending("alpha", pub)
    {:ok, _} = Admission.decide("alpha", "approved", "agent", "checked", 0)
    {:ok, _} = Admission.decide("alpha", "probation", "agent", "watch", 4_000_000_000)

    assert %{"pending" => [], "probation" => [%{"handle" => "alpha"}]} = Admission.queue()

    {:ok, audit} = Admission.audit(0)
    assert Enum.map(audit, & &1["status"]) == ["approved", "probation"]
    assert Enum.all?(audit, &(&1["by"] == "agent"))
  end

  test "a report is filed once and carries its reporter", %{pub: pub} do
    {:ok, _} = Admission.pending("alpha", pub)

    assert {:ok, %{"id" => 1, "handle" => "alpha", "by" => "beta"}} =
             Admission.report("alpha", "beta", "spam", "posted the same words everywhere")

    assert {:error, :self_report} = Admission.report("beta", "beta", "spam", "x")
    assert {:error, :bad_reason} = Admission.report("alpha", "beta", "dislike", "x")

    {:ok, reports} = Admission.reports(0)
    assert [%{"reason" => "spam"}] = reports
  end
end
