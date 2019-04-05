require "net/imap"

module Imap
  class Sync
    def initialize(group, provider = Imap::Providers::Generic)
      @group = group

      @provider = provider.new(group.imap_server,
        port: group.imap_port,
        ssl: group.imap_ssl,
        username: group.email_username,
        password: group.email_password
      )
    end

    def disconnect!
      @provider.disconnect!
    end

    def process(mailbox)
      @provider.connect!

      # Server-to-Discourse sync:
      #   - check mailbox validity
      #   - discover changes to old messages (flags and labels)
      #   - fetch new messages
      @status = @provider.open_mailbox(mailbox)

      if @status[:uid_validity] != mailbox.uid_validity
        Rails.logger.warn("UIDVALIDITY does not match, invalidating IMAP cache and resync emails.")
        mailbox.last_seen_uid = 0
      end

      # Fetching UIDs of already synchronized and newly arrived emails.
      # Some emails may be considered newly arrived even though they have been
      # previously processed if the mailbox has been invalidated (UIDVALIDITY
      # changed).
      start = Time.now # TODO: DELETEME
      if mailbox.last_seen_uid == 0
        old_uids = []
        new_uids = @provider.uids
      else
        old_uids = @provider.uids(to: mailbox.last_seen_uid) # 1 .. seen
        new_uids = @provider.uids(from: mailbox.last_seen_uid + 1) # seen+1 .. inf
      end
      Rails.logger.warn("Fetched #{old_uids.size + new_uids.size} UIDs in #{Time.now - start}s.") # TODO: DELETEME

      # It takes about ~1s to process 100 old emails (without content)
      # or 2 new emails (with content).
      old_uids = old_uids.sample(500) # 5s
      new_uids = new_uids[0..50] # 25s

      start = Time.now # TODO: DELETEME
      if old_uids.present?
        emails = @provider.emails(mailbox, old_uids, ["UID", "FLAGS", "LABELS"])
        emails.each do |email|
          incoming_email = IncomingEmail.find_by(
            imap_uid_validity: @status[:uid_validity],
            imap_uid: email["UID"]
          )

          update_topic(email, incoming_email, mailbox: mailbox)
        end
      end
      Rails.logger.warn("Processed #{old_uids.size} old emails in #{Time.now - start}s.") # TODO: DELETEME

      start = Time.now # TODO: DELETEME
      if new_uids.present?
        emails = @provider.emails(mailbox, new_uids, ["UID", "FLAGS", "LABELS", "RFC822"])
        emails.each do |email|
          begin
            receiver = Email::Receiver.new(email["RFC822"],
              force_sync: true,
              destinations: [{ type: :group, obj: @group }],
              uid_validity: @status[:uid_validity],
              uid: email["UID"]
            )
            receiver.process!

            update_topic(email, receiver.incoming_email, mailbox: mailbox)

            mailbox.last_seen_uid = email["UID"]
          rescue Email::Receiver::ProcessingError => e
          end
        end
      end
      Rails.logger.warn("Processed #{new_uids.size} new emails in #{Time.now - start}s.") # TODO: DELETEME

      mailbox.update!(uid_validity: @status[:uid_validity])

      # Discourse-to-server sync:
      #   - sync flags and labels
      start = Time.now # TODO: DELETEME
      if !SiteSetting.imap_read_only
        @provider.open_mailbox(mailbox, true)
        IncomingEmail.where(imap_sync: true).each do |incoming_email|
          update_email(mailbox, incoming_email)
        end
      end
      Rails.logger.warn("Synchronized emails in #{Time.now - start}s.") # TODO: DELETEME
    end

    def update_topic(email, incoming_email, opts = {})
      return if incoming_email&.post&.post_number != 1 || incoming_email.imap_sync

      topic = incoming_email.topic

      update_topic_archived_state(email, topic, opts)
      update_topic_tags(email, topic, opts)
    end

    private

    def update_topic_archived_state(email, topic, opts = {})
      topic_is_archived = topic.group_archived_messages.length > 0
      email_is_archived = !email["LABELS"].include?("\\Inbox") && !email["LABELS"].include?("INBOX")

      if topic_is_archived && !email_is_archived
        GroupArchivedMessage.move_to_inbox!(@group.id, topic, skip_imap_sync: true)
      elsif !topic_is_archived && email_is_archived
        GroupArchivedMessage.archive!(@group.id, topic, skip_imap_sync: true)
      end
    end

    def update_topic_tags(email, topic, opts = {})
      tags = []
      tags << @provider.to_tag(opts[:mailbox].name) if opts[:mailbox]
      email["FLAGS"].each { |flag| tags << @provider.to_tag(flag) }
      email["LABELS"].each { |label| tags << @provider.to_tag(label) }
      tags.reject!(&:blank?)
      tags.uniq!

      # TODO: Optimize tagging.
      # `DiscourseTagging.tag_topic_by_names` does a lot of lookups in the
      # database and some of them could be cached in this context.
      DiscourseTagging.tag_topic_by_names(topic, Guardian.new(Discourse.system_user), tags)
    end

    def update_email(mailbox, incoming_email)
      return if !SiteSetting.tagging_enabled || !SiteSetting.allow_staff_to_tag_pms
      return if incoming_email&.post&.post_number != 1 || !incoming_email.imap_sync
      return unless email = @provider.emails(mailbox, incoming_email.imap_uid, ["FLAGS", "LABELS"]).first
      incoming_email.update(imap_sync: false)

      labels = email["LABELS"]
      flags = email["FLAGS"]
      topic = incoming_email.topic

      # Sync topic status and labels with email flags and labels.
      tags = topic.tags.pluck(:name)
      new_flags = tags.map { |tag| @provider.tag_to_flag(tag) }.reject(&:blank?)
      new_labels = tags.map { |tag| @provider.tag_to_label(tag) }.reject(&:blank?)
      new_labels << "\\Inbox" if topic.group_archived_messages.length == 0
      @provider.store(incoming_email.imap_uid, "FLAGS", flags, new_flags)
      @provider.store(incoming_email.imap_uid, "LABELS", labels, new_labels)
    end
  end

end
