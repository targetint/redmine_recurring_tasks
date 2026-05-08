class AdminRecurringTasksController < ApplicationController
  layout 'admin'
  before_action :require_admin

  def index
    @projects = Project.all.sorted
    scope = RecurringTask.includes(issue: :project, tracker: [])
    if params[:project_id].present?
      @selected_project_id = params[:project_id].to_i
      scope = scope.joins(:issue).where(issues: { project_id: @selected_project_id })
    end
    @recurring_tasks = scope.order(:id)
  end
end
