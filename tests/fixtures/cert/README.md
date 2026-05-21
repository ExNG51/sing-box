部分 fixture 为后续目标状态 fixture，当前生产代码可能尚不能生成。

These JSON files are baseline profiles for Task B and later TUIC work:

- `no-certificate.json`: no TLS certificate profile.
- `legacy-anytls-acme.json`: current legacy AnyTLS `tls.acme` shape for older sing-box cores.
- `provider-acme.json`: target/current sing-box 1.14+ `certificate_providers` shape.
- `file-cert-tuic.json`: target TUIC domain + file certificate shape.
- `self-signed-tuic.json`: current TUIC self-signed file certificate shape.
