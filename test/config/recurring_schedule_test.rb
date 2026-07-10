require "test_helper"
require "fugit"

class RecurringScheduleTest < ActiveSupport::TestCase
  test "every production recurring task names a real job or command and a parseable schedule" do
    tasks = YAML.load_file(Rails.root.join("config", "recurring.yml"))["production"]

    assert_includes tasks.keys, "sync_quotas"
    assert_includes tasks.keys, "prune_retention"

    tasks.each do |name, task|
      assert task["class"].present? || task["command"].present?, "#{name} needs a class or command"
      if task["class"]
        assert task["class"].constantize < ActiveJob::Base, "#{name} must name an ActiveJob class"
      end
      assert Fugit.parse(task["schedule"]), "#{name} schedule #{task["schedule"].inspect} must parse"
    end
  end
end
