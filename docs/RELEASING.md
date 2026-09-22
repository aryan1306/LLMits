# Releasing LLMits

Tagged releases publish the DMG and checksum to GitHub Releases and mirror both
files to Cloudflare R2. The mirror keeps immutable versioned objects and a
small `latest` pointer:

```text
releases/v1.2.3/LLMits.dmg
releases/v1.2.3/LLMits.dmg.sha256
latest/version.txt
```

## Cloudflare setup

1. Use the `llmits-releases` R2 bucket and an API token scoped to **Object Read
   & Write** for that bucket.
2. Keep `llmits.aryansinghal.in` connected to the bucket with Cloudflare caching
   enabled.
3. Add these GitHub repository settings:

   - Secret `CLOUDFLARE_API_TOKEN`
   - Secret `CLOUDFLARE_ACCOUNT_ID`
   - Variable `R2_BUCKET_NAME`

4. The installer uses `https://llmits.aryansinghal.in` as its default CDN.

The version pointer is uploaded only after both immutable assets, preventing a
new DMG from being paired with an older cached checksum. The installer tries
the CDN first and automatically falls back to GitHub for each asset. Set
`LLMITS_CDN_BASE_URL` to override the configured mirror while testing:

```sh
LLMITS_CDN_BASE_URL=https://downloads.example.com ./install.sh --user
```

Push a version tag such as `v1.2.3`, or run the **Build DMG** workflow manually
to backfill an existing version. The workflow fails if any required Cloudflare
setting is missing so a release cannot silently skip the mirror.
