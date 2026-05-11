class RecurringTask < ActiveRecord::Base
  UnauthorizedError = Class.new(StandardError)

  belongs_to :issue
  belongs_to :tracker
  belongs_to :author, class_name: 'User', optional: true

  validates :issue_id,    presence: true, uniqueness: true
  validates :tracker_id,  presence: true

  validates :time, presence: true

  DAYS = %w(monday tuesday wednesday thursday friday saturday sunday).freeze

  RUN_TYPE_W_DAYS = :week_days
  RUN_TYPE_M_DAYS = :month_days

  attr_accessor :client_run_type

  before_save do
    if client_run_type.present?
      if client_run_type == RUN_TYPE_M_DAYS.to_s
        DAYS.each{|d| public_send("#{d}=", false)}
      else
        self.month_days = []
      end
    end
  end

  before_create do
    self.author ||= User.current
  end

  # @return [Array<String>] array of days when schedule should be executed
  def days
    DAYS.select{|d| public_send(d)}
  end

  def months=(value)
    value ||= default_months
    super(value.to_json)
  end

  def months
    result = super
    JSON.parse(result)
  rescue
    raise result
  end

  def month_days=(value)
    value ||= default_month_days
    super(value.to_json)
  end

  def time=(value)
    value = Time.new(*value.values) if value.is_a?(Hash)

    return super(value.to_time) unless value.respond_to?(:utc)
    super(value.dup.utc)
  end

  def time
    super&.localtime
  end

  def month_days
    result = super
    result = JSON.parse(result)
  rescue
    raise result
  end

  def month_days_parsed
    month_days.map{|x| x == 'last_day' ? Time.now.end_of_month.day.to_s : x}.compact.uniq
  end

  def self.schedules(current_time = Time.now)
    week_day  = current_time.strftime('%A').downcase
    month_day = current_time.day
    # months
    scope = where("months LIKE '%\"#{current_time.month.to_s}\"%'")

    scope.select do |schedule|
      if schedule.month_days.empty?
        # week day
        next unless schedule.public_send(week_day)
      else
        # month day
        month_days = schedule.month_days_parsed
        next unless month_days.include?(month_day.to_s)
      end
      # time
      schedule.time_came?(current_time)
    end
  end

  # @return [Issue] copied issue
  def copy_issue(associations = [])
    return if issue.project.archived? || issue.project.closed?
    copied_to = nil
    selected_associations = Array(associations).map(&:to_s).reject(&:blank?)
    settings = Setting.find_by(name: :plugin_redmine_recurring_tasks)&.value || {}
    logger.info("RecurringTask ##{id}: start copying issue ##{issue.id}")
    begin
      # Create the issue first, then copy selected associations in a second phase.
      issue.deep_clone(include: [], except: %i[parent_id root_id lft rgt created_on updated_on closed_on]) do |original, copy|
        case original
        when Issue
          logger.info("RecurringTask ##{id}: copying source issue ##{original.id}")
          copy.init_journal(original.author)
          new_author =
            if settings['use_anonymous_user']
              User.anonymous
            else
              unless original.author.allowed_to?(:copy_issues, issue.project)
                raise UnauthorizedError, "User #{original.author.name} (##{original.author.id}) unauthorized to copy issues"
              end
              original.author
              # User.current = original.author
            end
          copy.custom_field_values = original.custom_field_values.inject({}) { |h, v| h[v.custom_field_id] = v.value; h }
          copy.author_id = new_author.id
          copy.tracker_id = original.tracker_id
          copy.parent_issue_id = original.parent_issue_id
          copy.status_id =
            case settings['copied_issue_status']
            when nil
              copy.new_statuses_allowed_to(original.author).sort_by(&:position).first&.id
            when '0'
              original.status_id
            else
              settings['copied_issue_status']
            end

          copy.start_date = Time.now

          copied_to = copy
          if original.due_date.present?
            issue_date = (original.start_date || original.created_on).to_date
            copy.due_date = copy.start_date + (original.due_date.to_date - issue_date)
          end
        else
          next
        end
      end.tap { |copy| copy.save!(validate: false) }

      copy_associations_after_creation!(copied_to, selected_associations)
      
      issue.relations_from.create(issue_to_id: copied_to.id, relation_type: "copied_to")
      logger.info("RecurringTask ##{id}: issue ##{issue.id} copied to ##{copied_to&.id}")
    rescue ActiveRecord::StaleObjectError
      copied_to.reload
      retry
    rescue StandardError => e
      log_error(e)
      raise
    end
  end

  # @return [Boolean] boolean result of copy issue and save of schedule last try timestamp
  def execute(associations = nil)
    update_column(:last_try_at, Time.now)
    copy_issue(associations).present?
  end

  # @return [Symbol] return :month_days if any month days are present, else :week_days
  def run_type
    self.month_days.any? ? RUN_TYPE_M_DAYS : RUN_TYPE_W_DAYS
  end

  def time_came?(current_time = Time.now)
    current_localtime = current_time.localtime
    scheduled_time = (time.hour * 60) + time.min
    current_time_of_day = (current_localtime.hour * 60) + current_localtime.min

    self.months.include?(current_localtime.month.to_s) &&
      (day_check(current_localtime.wday) || self.month_days_parsed.include?(current_localtime.day.to_s)) &&
      scheduled_time <= current_time_of_day &&
      (last_try_at.blank? || last_try_at.localtime.to_date < current_localtime.to_date)
    # utc_offset = current_time.utc_offset / 60 / 60
    # utc_offset -= 1 if time.in_time_zone(utc_offset).dst?
    # time.in_time_zone(utc_offset).strftime('%H%M%S').to_i <= current_time.strftime('%H%M%S').to_i &&
    #   (last_try_at.nil? || last_try_at.in_time_zone(utc_offset).strftime('%Y%m%d').to_i < current_time.strftime('%Y%m%d').to_i)
  end

  def day_check(current_day)
    _days = {'0'=>'sunday','1'=>'monday','2'=>'tuesday','3'=>'wednesday','4'=>'thursday','5'=>'friday','6'=>'saturday'}
    return self.send(_days[current_day.to_s].to_sym)
  end

  private

  def copy_associations_after_creation!(copied_issue, associations)
    associations.each do |association_name|
      begin
        logger.info("RecurringTask ##{id}: copying association #{association_name} for issue ##{copied_issue.id}")
        copy_single_association!(copied_issue, association_name)
      rescue StandardError => e
        logger.error("RecurringTask ##{id}: association #{association_name} copy failed for issue ##{copied_issue.id}: #{e.message}")
      end
    end
  end

  def copy_single_association!(copied_issue, association_name)
    case association_name
    when 'taggings', 'tags'
      copied_issue.taggings.destroy_all if copied_issue.respond_to?(:taggings)
      issue.tags.each { |tag| copied_issue.tags << tag } if copied_issue.respond_to?(:tags)
    when 'watcher_users', 'watchers'
      copied_issue.watcher_user_ids = issue.watcher_users.select { |u| u.status == User::STATUS_ACTIVE }.map(&:id)
    when 'attachments'
      copied_issue.attachments = issue.attachments.map { |attachment| attachment.copy(container: copied_issue) }
    else
      reflection = Issue.reflect_on_association(association_name.to_sym)
      return if reflection.nil?

      return unless reflection.collection?

      source_records = issue.public_send(association_name)
      ids_writer = "#{association_name.to_s.singularize}_ids="

      if copied_issue.respond_to?(ids_writer) && source_records.respond_to?(:pluck)
        copied_issue.public_send(ids_writer, source_records.pluck(:id))
      elsif copied_issue.respond_to?(ids_writer)
        copied_issue.public_send(ids_writer, source_records.map(&:id))
      else
        logger.info("RecurringTask ##{id}: skipped association #{association_name}; no ids writer present")
      end
    end
  end

  def log_error(e)
    logger.error e.to_s
    logger.error e.backtrace.join("\n")
  end

  # @return [Logger] a log class
  def logger
    @logger ||= Logger.new(Rails.root.join('log', 'redmine_recurring_tasks.log'))
  end

  def default_month_days
    []
  end

  def default_months
    (1..12).to_a.map(&:to_s)
  end
end
