# 2026-08-16 — UDP per-connection token (the second half of the CelesteNet measure)

<!-- ADR 0024. Indexed in ../architecture.md, which is the decision log front door. -->

- **Decision:** After admission, every udp application datagram carries an unpredictable 64-bit
  per-connection token issued by the listener. Datagrams without it, or with the wrong one, are
  dropped — including bare NDJSON lines, which were previously valid unreliable payloads.
- **Status:** Implemented, same day, prompted by the user asking whether the CelesteNet UDP
  measures were needed here.
- **Context:** The transport shipped with an address-validation cookie, which gates **admission**
  — it proves a source address is real, defeating blind spoofing and reflection. It does nothing
  afterwards: a connection was identified by source address alone, so anyone able to spoof a live
  client's ip:port could inject state into its session. `docs/security.md` had cited CelesteNet's
  unpredictable token as precisely the reason TCP is safer by construction, and then the udp
  transport shipped without it.
- **Options considered:** (1) leave it and document the gap — defensible on threat modelling
  alone, since exploiting it needs the victim's IP from outside MeshGhost (the relay never calls
  `RemoteAddr`), source-IP spoofing that most ISPs filter, and pays out only in cosmetic griefing;
  (2) add the token.
- **Resolution:** Option 2, and the deciding argument was not the threat model but the
  documentation: shipping a udp transport that omits the exact measure our own prior-art notes
  cite as making TCP safer is a claim the code fails to honour. 64 bits clears the bar TCP's
  32-bit sequence number sets. Cost is 8 bytes per datagram, ~4% on a typical state message.
- **Resolution (bare payloads had to go):** Unframed NDJSON datagrams were dropped, because
  leaving them accepted would have made the token optional in practice — a sender could simply not
  use it. This cost the "a datagram is literally a greppable NDJSON line" property, which was
  genuinely nice and is now gone on udp.
- **Consequences:** Two distinct defences with two distinct jobs, documented as such: the cookie
  gates admission, the token gates the session. **Neither is encryption** — an on-path attacker
  reads both straight off the wire, the same limit TCP sequence numbers have, and the reason
  `quic` exists. Covered by a forged-datagram regression test and a bypass test, with fuzz seeds
  for every token-carrying frame shape. Technique taken from prior-art notes only; no CelesteNet
  code was read or copied, per `licensing.md`'s facts-not-code rule.
