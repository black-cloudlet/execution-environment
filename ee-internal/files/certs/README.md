# Internal CA certificates

Put PEM-encoded internal CA certificates here as `*.crt` or `*.pem`, for
example `corp-root-ca.crt`. They are used in three places:

- **Image build.** They are installed into the system trust store in every
  stage, so `ansible-galaxy` can reach Private Automation Hub. They stay in
  the final image for jobs that call internal TLS endpoints.
- **CI jobs.** `.gitlab-ci.yml` appends them to the tools image's CA bundle
  (`SSL_CERT_FILE` / `CURL_CA_BUNDLE`). That covers buildah, skopeo, cosign
  and curl when they talk to Quay, PAH and AAP.

Only public CA certificates belong here, never private keys. Files other than
`*.crt` / `*.pem` (such as this README) are ignored.
