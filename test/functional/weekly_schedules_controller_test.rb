require File.expand_path('../../test_helper', __FILE__)

class WeeklySchedulesControllerTest < ActionController::TestCase
  fixtures :projects,
           :users,
           :roles,
           :members,
           :member_roles,
           :trackers,
           :projects_trackers,
           :issue_statuses,
           :issues

  def setup
    Role.find(1).add_permission! :manage_schedule
    Role.find(1).add_permission! :view_schedule
  end

  def test_new
    @request.session[:user_id] = 2

    with_settings default_language: 'en' do
      get :new, issue_id: 1

      assert_response :success
      assert_template 'new'
      assert_select 'legend', text: 'Cannot print recipes'
    end
  end

  def test_new_wrong_issue
    @request.session[:user_id] = 2

    with_settings default_language: 'en' do
      get :new, issue_id: 666
      assert_response :not_found
    end
  end

  def test_new_empty_issue
    @request.session[:user_id] = 2

    with_settings default_language: 'en' do
      get :new
      assert_response :not_found
    end
  end
end