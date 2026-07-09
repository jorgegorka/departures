> **Status: PENDING MANUAL RUN** — requires SES sandbox credentials + two verified inboxes. Must be completed before Phase 5 enables real sending. Run protocol below.

## Run protocol

```bash
AWS_REGION=eu-west-1 SES_KEY=AKIA... SES_SECRET=... \
FROM=verified-sender@yourdomain.com TO=inbox-a@yourdomain.com BCC=inbox-b@yourdomain.com \
bin/rails runner '
  project = Project.first
  Current.workspace = project.workspace

  source = project.sources.create!(name: "Bcc spike", environment: "spike",
    region: ENV.fetch("AWS_REGION"), aws_access_key_id: ENV.fetch("SES_KEY"),
    aws_secret_access_key: ENV.fetch("SES_SECRET"), retention_days: 1)

  email = Email.create!(project: project, source: source, from: ENV.fetch("FROM"),
    subject: "Departures bcc spike", html_body: "<p>bcc spike</p>", text_body: "bcc spike")
  email.recipients.create!(kind: "to", address: ENV.fetch("TO"))
  email.recipients.create!(kind: "bcc", address: ENV.fetch("BCC"))

  Email::MimeStore.write(email, Email::MimeBuilder.new(email).to_eml)
  email.deliver
  puts "sent: #{email.ses_message_id.inspect} status: #{email.status}"

  # Variant B — headers-only raw send (no Destination), to document SES default behavior:
  email.source.ses_client.send_email(content: { raw: { data: Email::MimeStore.read(email) } })
  puts "variant B sent (recipients derived from MIME headers — bcc inbox should get NOTHING)"

  source.destroy
'
```

Then check both inboxes ("view raw source" on each message).

# Bcc semantics — SESv2 raw send (risk #2 spike)

Date: <!-- fill in -->  Region: <!-- fill in -->  SDK: aws-sdk-sesv2 <!-- version -->

## Design under test
MimeBuilder never writes a Bcc header; Deliverable passes
`destination: { to_addresses:, cc_addresses:, bcc_addresses: }` alongside `content: { raw: }`.

## Checklist (Variant A — explicit Destination)
- [ ] BCC inbox received the message
- [ ] TO inbox received the message
- [ ] Raw source of the TO copy contains NO `Bcc:` header and no bcc address anywhere
- [ ] Raw source of the BCC copy contains NO `Bcc:` header (recipient can't be re-leaked)
- [ ] `Message-ID` in received copies equals `<{public_id}@{from_domain}>` (SES preserved it) — if SES
      rewrote it, note the observed value; Phase 3 matches on `ses_message_id`, not Message-ID, so this
      is informational
- [ ] `X-Departures-Id` header present in received copies

## Checklist (Variant B — no Destination, recipients derived from headers)
- [ ] TO inbox received the message
- [ ] BCC inbox received NOTHING (bcc address is in no header, so SES cannot derive it)
- [ ] Confirms: omitting Destination would silently drop bcc recipients → Destination stays mandatory

## Verdict
<!-- confirm MimeBuilder/Deliverable as built, or describe the adjustment made -->
