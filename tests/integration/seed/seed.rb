# 結合テスト用のデータを作る（何度実行してもよい）
Redmine::DefaultData::Loader.load('ja') if Redmine::DefaultData::Loader.no_data?
Setting.rest_api_enabled = '1'

admin = User.find_by_login('admin')
admin.must_change_passwd = false
admin.save!

def ensure_project(identifier, name, status)
  project = Project.find_by_identifier(identifier) || Project.new(name: name, identifier: identifier)
  project.tracker_ids = Tracker.pluck(:id)
  project.enabled_module_names = ['issue_tracking']
  project.save!
  project.update_column(:status, status)
  project
end

project = ensure_project('rmbulk-test', 'rmbulk テスト', Project::STATUS_ACTIVE)
ensure_project('closed-proj', '終了プロジェクト', Project::STATUS_CLOSED)
Version.find_or_create_by!(project: project, name: 'v1.0')
Version.find_or_create_by!(project: project, name: 'old').update!(status: 'closed')

puts "APIKEY=#{admin.api_key}"
