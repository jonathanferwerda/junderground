defmodule Junderground.RecordTest do
  use ExUnit.Case, async: true

  alias Junderground.{Canonical, Keys, Record}

  setup do
    {pub, priv} = Keys.generate()
    %{pub: pub, priv: priv}
  end

  defp signed(kind, pub, priv, seq, fields \\ %{}) do
    Record.build(kind, "alpha", pub, seq, fields) |> Keys.sign_record(priv)
  end

  defp head(record, pub) do
    %{"seq" => record["seq"], "sig" => record["sig"], "pubkey" => pub, "tombstoned" => false}
  end

  test "a first registration validates", %{pub: pub, priv: priv} do
    assert Record.validate(signed("register", pub, priv, 1), nil) == :ok
  end

  test "a first registration must start at sequence 1", %{pub: pub, priv: priv} do
    assert Record.validate(signed("register", pub, priv, 2), nil) == {:error, :bad_first_seq}
  end

  test "tampering breaks the signature", %{pub: pub, priv: priv} do
    record = signed("register", pub, priv, 1) |> Map.put("name", "Mallory")
    refute Keys.verify_record(record)
    assert Record.validate(record, nil) == {:error, :bad_signature}
  end

  test "a route chains on prev and seq", %{pub: pub, priv: priv} do
    first = signed("register", pub, priv, 1)
    route = signed("route", pub, priv, 2, %{"prev" => first["sig"]})
    assert Record.validate(route, head(first, pub)) == :ok
  end

  test "a broken prev, a gap, and a stale sequence are refused", %{pub: pub, priv: priv} do
    first = signed("register", pub, priv, 1)
    prior = head(first, pub)

    assert Record.validate(signed("route", pub, priv, 2, %{"prev" => "nope"}), prior) ==
             {:error, :broken_chain}

    assert Record.validate(signed("route", pub, priv, 3, %{"prev" => first["sig"]}), prior) ==
             {:error, :gap}

    assert Record.validate(signed("route", pub, priv, 1, %{"prev" => first["sig"]}), prior) ==
             {:error, :stale}
  end

  test "a different key cannot take the handle over", %{pub: pub, priv: priv} do
    first = signed("register", pub, priv, 1)
    {other_pub, other_priv} = Keys.generate()
    takeover = signed("register", other_pub, other_priv, 2, %{"prev" => first["sig"]})
    assert Record.validate(takeover, head(first, pub)) == {:error, :taken}
  end

  test "a rotation moves signing authority", %{pub: pub, priv: priv} do
    first = signed("register", pub, priv, 1)
    {next_pub, next_priv} = Keys.generate()

    rotate =
      signed("rotate", pub, priv, 2, %{"prev" => first["sig"], "new_pubkey" => next_pub})

    assert Record.validate(rotate, head(first, pub)) == :ok
    assert Record.active_pubkey(rotate) == next_pub

    # the old key is no longer the house's key
    wrong = signed("route", pub, priv, 3, %{"prev" => rotate["sig"]})
    assert Record.validate(wrong, head(rotate, next_pub)) == {:error, :wrong_key}

    # the new key is
    right = signed("route", next_pub, next_priv, 3, %{"prev" => rotate["sig"]})
    assert Record.validate(right, head(rotate, next_pub)) == :ok
  end

  test "a tombstone retires the handle", %{pub: pub, priv: priv} do
    first = signed("register", pub, priv, 1)

    tombstone = signed("tombstone", pub, priv, 2, %{"prev" => first["sig"]})
    assert Record.validate(tombstone, head(first, pub)) == :ok

    prior = %{"seq" => 2, "sig" => tombstone["sig"], "pubkey" => pub, "tombstoned" => true}

    assert Record.validate(signed("route", pub, priv, 3, %{"prev" => tombstone["sig"]}), prior) ==
             {:error, :retired}

    # the same key may return, with a higher sequence
    assert Record.validate(signed("register", pub, priv, 3, %{"prev" => tombstone["sig"]}), prior) ==
             :ok
  end

  # Produced by jawnos' own signer: Crypt::PK::Ed25519 over
  # JSON::PP->new->canonical(1) of the record with "sig" removed. If the bytes
  # ever drift from the Perl side, this test fails.
  @perl_canonical "eyJmb3JtYXQiOiJqdW5kZXJncm91bmQtaG91c2UiLCJoYW5kbGUiOiJmaXh0dXJlIiwiaXNzdWVkIjoxNzYwMDAwMDAwLCJraW5kIjoicmVnaXN0ZXIiLCJuYW1lIjoiRml4dHVyZSBIb3VzZSIsInB1YmtleSI6IkM2L3BaQTRMVzVJVnZ2ODU4MVZ3SGNUY2pubnJPZFBoY3MvRTlOS3JZT009Iiwicm91dGVzIjp7IndzcyI6IndzczovL2ZpeHR1cmUuZXhhbXBsZS92MS9zaWduYWwifSwic2VxIjoxLCJ2ZXJzaW9uIjoxLCJ2aXNpYmlsaXR5IjoicHVibGljIn0="
  @perl_record "eyJmb3JtYXQiOiJqdW5kZXJncm91bmQtaG91c2UiLCJoYW5kbGUiOiJmaXh0dXJlIiwiaXNzdWVkIjoxNzYwMDAwMDAwLCJraW5kIjoicmVnaXN0ZXIiLCJuYW1lIjoiRml4dHVyZSBIb3VzZSIsInB1YmtleSI6IkM2L3BaQTRMVzVJVnZ2ODU4MVZ3SGNUY2pubnJPZFBoY3MvRTlOS3JZT009Iiwicm91dGVzIjp7IndzcyI6IndzczovL2ZpeHR1cmUuZXhhbXBsZS92MS9zaWduYWwifSwic2VxIjoxLCJzaWciOiJ3MjNadm1GUGp0MXpOblBtNUdtaEh0NzB2amhBUUdzTWZRWGtOeWFZQ0hnNTJ6Y0Q0TDJxQlBpWkhJMlZqVWRITC81dU1HN1grUjZhNXBQclB0Q3FDUT09IiwidmVyc2lvbiI6MSwidmlzaWJpbGl0eSI6InB1YmxpYyJ9"

  test "a record signed by jawnos' Perl side verifies byte for byte" do
    record = @perl_record |> Base.decode64!() |> JSON.decode!()

    assert Canonical.encode(Map.delete(record, "sig")) == Base.decode64!(@perl_canonical)
    assert Keys.verify_record(record)
    assert Record.validate(record, nil) == :ok
  end

  test "a crest must be the key that signed the record", %{pub: pub, priv: priv} do
    crest = %{"uuid" => "house-uuid", "name" => "Alpha", "pubkey" => pub}
    assert Record.validate(signed("register", pub, priv, 1, %{"crest" => crest}), nil) == :ok

    {other_pub, _other_priv} = Keys.generate()
    wrong = Map.put(crest, "pubkey", other_pub)

    assert Record.validate(signed("register", pub, priv, 1, %{"crest" => wrong}), nil) ==
             {:error, :bad_crest}

    wrong_fingerprint = Map.put(crest, "fingerprint", "0000 0000")

    assert Record.validate(signed("register", pub, priv, 1, %{"crest" => wrong_fingerprint}), nil) ==
             {:error, :bad_crest}
  end
end
