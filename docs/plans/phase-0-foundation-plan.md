# Phase 0 — Foundation: Auth, Tenancy, Membership — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Session auth (Rails 8 generator), gated registration, multi-workspace tenancy (Workspace/Membership/Invitation/Project) with the 6-role capability map, workspace-aware controllers and jobs, and the CSS foundation.

**Architecture:** Everything follows `docs/patterns-and-best-practices.md`: business logic in models composed from namespaced concerns, thin RESTful controllers, `Current`-based tenancy, lambda association defaults, Minitest + fixtures. Views use the token system from `docs/style-guide.md`.

**Tech Stack:** Rails 8.1, SQLite, bcrypt (via auth generator), Minitest.

## Global Constraints

- Default integer primary keys.
- Registration open only while `User.none?` or `ENV["OPEN_REGISTRATION"]` present.
- Roles: `owner member sender api_keys domains read_only`; capabilities: `send manage_api_keys manage_domains manage_templates manage_webhooks manage_members`.
- Cross-workspace access → 404 (`RecordNotFound` from scoped finds); missing capability → 403.
- Style rules from patterns §5.1 apply to all code: expanded conditionals, private methods indented and in invocation order, bang methods only with non-bang counterparts.
- Every task ends with `bin/rails test` green and a commit. Run `bin/rubocop -a` before each commit.

**Task prelude (all tasks):** re-read patterns doc Part 2 (models), §4.1–4.3 (controllers), §5.1 (style). Task 10 additionally: style-guide.md in full.

---

### Task 1: Authentication generator + Current extension

**Files:**
- Generated: `app/models/user.rb`, `app/models/session.rb`, `app/models/current.rb`, `app/controllers/sessions_controller.rb`, `app/controllers/passwords_controller.rb`, `app/controllers/concerns/authentication.rb`, migrations, mailer
- Modify: `app/models/current.rb`, `Gemfile` (generator uncomments bcrypt)
- Test: `test/models/current_test.rb`

**Interfaces:**
- Produces: `Current.session`, `Current.user` (delegated), `Current.workspace`, `Current.project` — used by every later task. `Authentication` concern with `require_authentication` / `allow_unauthenticated_access`.

- [ ] **Step 1: Run the generator and migrate**

```bash
bin/rails generate authentication
bundle install
bin/rails db:migrate
```

Expected: `User`, `Session`, `Current` models; sessions/passwords controllers; `Authentication` concern included in `ApplicationController`.

- [ ] **Step 2: Write the failing test for Current extensions**

```ruby
# test/models/current_test.rb
require "test_helper"

class CurrentTest < ActiveSupport::TestCase
  test "workspace and project are settable attributes" do
    Current.workspace = workspaces(:acme)
    Current.project = projects(:acme_default)

    assert_equal workspaces(:acme), Current.workspace
    assert_equal projects(:acme_default), Current.project
  end
end
```

Note: `workspaces`/`projects` fixtures arrive in Tasks 3/5. Until then use `Current.workspace = :anything` placeholder assertion; tighten in Task 5. To keep this task self-contained, assert with a plain object:

```ruby
# test/models/current_test.rb
require "test_helper"

class CurrentTest < ActiveSupport::TestCase
  test "workspace and project are settable attributes" do
    Current.workspace = "workspace-sentinel"
    Current.project = "project-sentinel"

    assert_equal "workspace-sentinel", Current.workspace
    assert_equal "project-sentinel", Current.project
  end
end
```

- [ ] **Step 3: Run test to verify it fails**

Run: `bin/rails test test/models/current_test.rb`
Expected: FAIL — `NoMethodError: undefined method 'workspace='`

- [ ] **Step 4: Extend Current**

```ruby
# app/models/current.rb
class Current < ActiveSupport::CurrentAttributes
  attribute :session
  attribute :workspace, :project

  delegate :user, to: :session, allow_nil: true
end
```

- [ ] **Step 5: Run tests to verify pass**

Run: `bin/rails test`
Expected: PASS (generated tests + current_test)

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "feat: add session authentication and workspace-aware Current"
```

---

### Task 2: Registration gating

**Files:**
- Create: `app/controllers/registrations_controller.rb`, `app/views/registrations/new.html.erb`
- Modify: `app/models/user.rb`, `config/routes.rb`
- Test: `test/controllers/registrations_controller_test.rb`, `test/models/user_test.rb`, `test/fixtures/users.yml`

**Interfaces:**
- Produces: `User.registration_open?` → boolean; routes `new_registration_path` / `registration_path` (POST). Task 4 replaces the controller's `User.create!` with `User.create_owner`.

- [ ] **Step 1: Write failing model test**

```ruby
# test/models/user_test.rb
require "test_helper"

class UserTest < ActiveSupport::TestCase
  test "registration_open? is true when there are no users" do
    User.delete_all

    assert User.registration_open?
  end

  test "registration_open? is false when users exist" do
    assert_not User.registration_open?
  end

  test "registration_open? is true with OPEN_REGISTRATION set" do
    ENV["OPEN_REGISTRATION"] = "true"

    assert User.registration_open?
  ensure
    ENV.delete("OPEN_REGISTRATION")
  end
end
```

```yaml
# test/fixtures/users.yml
jorge:
  email_address: jorge@example.com
  password_digest: <%= BCrypt::Password.create("secret123456") %>
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bin/rails test test/models/user_test.rb`
Expected: FAIL — `NoMethodError: undefined method 'registration_open?'`

- [ ] **Step 3: Implement**

```ruby
# app/models/user.rb
class User < ApplicationRecord
  has_secure_password
  has_many :sessions, dependent: :destroy

  normalizes :email_address, with: ->(e) { e.strip.downcase }

  class << self
    def registration_open?
      none? || ENV["OPEN_REGISTRATION"].present?
    end
  end
end
```

- [ ] **Step 4: Run test to verify pass**

Run: `bin/rails test test/models/user_test.rb`
Expected: PASS

- [ ] **Step 5: Write failing controller test**

```ruby
# test/controllers/registrations_controller_test.rb
require "test_helper"

class RegistrationsControllerTest < ActionDispatch::IntegrationTest
  test "first user can register" do
    User.delete_all

    assert_difference -> { User.count }, +1 do
      post registration_url, params: { email_address: "first@example.com",
        password: "secret123456", password_confirmation: "secret123456" }
    end

    assert_redirected_to root_url
  end

  test "registration is closed when users exist" do
    assert_no_difference -> { User.count } do
      post registration_url, params: { email_address: "second@example.com",
        password: "secret123456", password_confirmation: "secret123456" }
    end

    assert_response :not_found
  end

  test "new is not available when registration closed" do
    get new_registration_url

    assert_response :not_found
  end
end
```

- [ ] **Step 6: Run to verify it fails**

Run: `bin/rails test test/controllers/registrations_controller_test.rb`
Expected: FAIL — `NameError: undefined ... registration_url`

- [ ] **Step 7: Implement controller, route, view**

```ruby
# config/routes.rb (add)
resource :registration, only: %i[ new create ]
```

```ruby
# app/controllers/registrations_controller.rb
class RegistrationsController < ApplicationController
  allow_unauthenticated_access

  before_action :ensure_registration_open

  def new
    @user = User.new
  end

  def create
    @user = User.create!(user_params)
    start_new_session_for @user
    redirect_to root_url
  end

  private
    def ensure_registration_open
      unless User.registration_open?
        head :not_found
      end
    end

    def user_params
      params.permit(:email_address, :password, :password_confirmation)
    end
end
```

```erb
<%# app/views/registrations/new.html.erb %>
<h1>Create your account</h1>

<%= form_with model: @user, url: registration_path, class: "flex flex-column gap" do |form| %>
  <div class="flex flex-column gap-half">
    <%= form.label :email_address %>
    <%= form.email_field :email_address, class: "input", required: true, autofocus: true %>
  </div>
  <div class="flex flex-column gap-half">
    <%= form.label :password %>
    <%= form.password_field :password, class: "input", required: true %>
  </div>
  <div class="flex flex-column gap-half">
    <%= form.label :password_confirmation %>
    <%= form.password_field :password_confirmation, class: "input", required: true %>
  </div>
  <%= form.submit "Create account", class: "btn btn--primary btn--medium" %>
<% end %>
```

- [ ] **Step 8: Run tests, verify pass**

Run: `bin/rails test`
Expected: PASS

- [ ] **Step 9: Commit**

```bash
git add -A
git commit -m "feat: gate registration to first user or OPEN_REGISTRATION"
```

---

### Task 3: Workspace, Membership, Workspace::Roles

**Files:**
- Create: migrations `create_workspaces`, `create_memberships`; `app/models/workspace.rb`, `app/models/membership.rb`, `app/models/workspace/roles.rb`
- Modify: `app/models/user.rb`
- Test: `test/models/workspace/roles_test.rb`, fixtures `workspaces.yml`, `memberships.yml`, expand `users.yml`

**Interfaces:**
- Produces: `workspace.capability?(user, capability)`, `workspace.role_for(user)`, `Workspace::Roles::ROLE_CAPABILITIES`, `user.workspaces` (through memberships). Consumed by Task 6's `authorize_capability!` and everything after.

- [ ] **Step 1: Migrations**

```ruby
# db/migrate/XXXX_create_workspaces.rb
class CreateWorkspaces < ActiveRecord::Migration[8.1]
  def change
    create_table :workspaces do |t|
      t.string :name, null: false
      t.string :slug, null: false, index: { unique: true }
      t.references :owner, null: false, foreign_key: { to_table: :users }
      t.datetime :setup_started_at
      t.datetime :onboarded_at
      t.timestamps
    end
  end
end
```

```ruby
# db/migrate/XXXX_create_memberships.rb
class CreateMemberships < ActiveRecord::Migration[8.1]
  def change
    create_table :memberships do |t|
      t.references :workspace, null: false, foreign_key: true
      t.references :user, null: false, foreign_key: true
      t.string :role, null: false
      t.timestamps
      t.index [ :workspace_id, :user_id ], unique: true
    end
  end
end
```

Run: `bin/rails db:migrate`

- [ ] **Step 2: Write failing role-matrix test**

```ruby
# test/models/workspace/roles_test.rb
require "test_helper"

class Workspace::RolesTest < ActiveSupport::TestCase
  CAPABILITIES = %w[ send manage_api_keys manage_domains manage_templates manage_webhooks manage_members ]

  EXPECTED = {
    "owner"     => CAPABILITIES,
    "member"    => CAPABILITIES - %w[ manage_members ],
    "sender"    => %w[ send ],
    "api_keys"  => %w[ manage_api_keys ],
    "domains"   => %w[ manage_domains ],
    "read_only" => []
  }.freeze

  test "role capability matrix" do
    EXPECTED.each do |role, allowed|
      user = users(role.to_sym)

      CAPABILITIES.each do |capability|
        assert_equal allowed.include?(capability),
          workspaces(:acme).capability?(user, capability),
          "expected #{role} / #{capability} to be #{allowed.include?(capability)}"
      end
    end
  end

  test "non-member has no capabilities" do
    CAPABILITIES.each do |capability|
      assert_not workspaces(:acme).capability?(users(:outsider), capability)
    end
  end

  test "role_for returns the membership role" do
    assert_equal "owner", workspaces(:acme).role_for(users(:owner))
    assert_nil workspaces(:acme).role_for(users(:outsider))
  end
end
```

```yaml
# test/fixtures/users.yml
jorge:
  email_address: jorge@example.com
  password_digest: <%= BCrypt::Password.create("secret123456") %>
<% %w[ owner member sender api_keys domains read_only outsider ].each do |name| %>
<%= name %>:
  email_address: <%= name %>@example.com
  password_digest: <%= BCrypt::Password.create("secret123456") %>
<% end %>
```

```yaml
# test/fixtures/workspaces.yml
acme:
  name: Acme
  slug: acme
  owner: owner

globex:
  name: Globex
  slug: globex
  owner: outsider
```

```yaml
# test/fixtures/memberships.yml
<% %w[ owner member sender api_keys domains read_only ].each do |role| %>
acme_<%= role %>:
  workspace: acme
  user: <%= role %>
  role: <%= role %>
<% end %>
globex_owner:
  workspace: globex
  user: outsider
  role: owner
```

- [ ] **Step 3: Run to verify fail**

Run: `bin/rails test test/models/workspace/roles_test.rb`
Expected: FAIL — `NameError: uninitialized constant Workspace`

- [ ] **Step 4: Implement models and concern**

```ruby
# app/models/workspace/roles.rb
module Workspace::Roles
  extend ActiveSupport::Concern

  ROLE_CAPABILITIES = {
    "owner"     => %w[ send manage_api_keys manage_domains manage_templates manage_webhooks manage_members ],
    "member"    => %w[ send manage_api_keys manage_domains manage_templates manage_webhooks ],
    "sender"    => %w[ send ],
    "api_keys"  => %w[ manage_api_keys ],
    "domains"   => %w[ manage_domains ],
    "read_only" => %w[]
  }.freeze

  def capability?(user, capability)
    ROLE_CAPABILITIES.fetch(role_for(user), []).include?(capability.to_s)
  end

  def role_for(user)
    memberships.find_by(user: user)&.role
  end
end
```

```ruby
# app/models/workspace.rb
class Workspace < ApplicationRecord
  include Roles

  belongs_to :owner, class_name: "User", default: -> { Current.user }

  has_many :memberships, dependent: :destroy
  has_many :users, through: :memberships

  validates :name, presence: true
  validates :slug, presence: true, uniqueness: true

  before_validation :assign_slug, on: :create

  private
    def assign_slug
      self.slug ||= name&.parameterize
    end
end
```

```ruby
# app/models/membership.rb
class Membership < ApplicationRecord
  belongs_to :workspace
  belongs_to :user

  validates :role, inclusion: { in: Workspace::Roles::ROLE_CAPABILITIES.keys }
  validates :user_id, uniqueness: { scope: :workspace_id }
end
```

```ruby
# app/models/user.rb (add associations)
  has_many :memberships, dependent: :destroy
  has_many :workspaces, through: :memberships
```

- [ ] **Step 5: Run to verify pass**

Run: `bin/rails test`
Expected: PASS

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "feat: workspaces, memberships, and role capability map"
```

---

### Task 4: First-user bootstrap (create_owner / create_with_owner)

**Files:**
- Modify: `app/models/user.rb`, `app/models/workspace.rb`, `app/controllers/registrations_controller.rb`
- Test: `test/models/user_test.rb`, `test/controllers/registrations_controller_test.rb`

**Interfaces:**
- Produces: `User.create_owner(attributes)` → User (with workspace + owner membership); `Workspace.create_with_owner(owner:, **attrs)` → Workspace. Task 7's `WorkspacesController#create` reuses `create_with_owner`.

- [ ] **Step 1: Write failing test**

```ruby
# test/models/user_test.rb (add)
  test "create_owner creates user, workspace, and owner membership" do
    user = nil

    assert_difference -> { User.count } => +1, -> { Workspace.count } => +1, -> { Membership.count } => +1 do
      user = User.create_owner(email_address: "founder@example.com",
        password: "secret123456", password_confirmation: "secret123456")
    end

    workspace = user.workspaces.sole
    assert_equal user, workspace.owner
    assert_equal "owner", workspace.role_for(user)
  end
```

- [ ] **Step 2: Run to verify fail**

Run: `bin/rails test test/models/user_test.rb`
Expected: FAIL — `NoMethodError: undefined method 'create_owner'`

- [ ] **Step 3: Implement**

```ruby
# app/models/workspace.rb (add inside class << self at top of class body, patterns §5.1 ordering)
  class << self
    def create_with_owner(owner:, **attributes)
      transaction do
        workspace = create!(owner: owner, **attributes)
        workspace.memberships.create!(user: owner, role: "owner")
        workspace
      end
    end
  end
```

```ruby
# app/models/user.rb (add inside existing class << self)
    def create_owner(attributes)
      transaction do
        user = create!(attributes)
        Workspace.create_with_owner(owner: user, name: default_workspace_name_for(user))
        user
      end
    end

    private
      def default_workspace_name_for(user)
        "#{user.email_address.split("@").first.capitalize}'s Workspace"
      end
```

```ruby
# app/controllers/registrations_controller.rb — change create body
  def create
    @user = User.create_owner(user_params)
    start_new_session_for @user
    redirect_to root_url
  end
```

- [ ] **Step 4: Add controller assertion**

```ruby
# test/controllers/registrations_controller_test.rb — extend the first test
  test "first user can register and becomes a workspace owner" do
    User.delete_all
    Membership.delete_all
    Workspace.delete_all

    assert_difference -> { User.count } => +1, -> { Workspace.count } => +1 do
      post registration_url, params: { email_address: "first@example.com",
        password: "secret123456", password_confirmation: "secret123456" }
    end

    assert_equal "owner", Workspace.sole.role_for(User.sole)
    assert_redirected_to root_url
  end
```

- [ ] **Step 5: Run, verify pass, commit**

Run: `bin/rails test`
Expected: PASS

```bash
git add -A
git commit -m "feat: first registered user bootstraps an owned workspace"
```

---

### Task 5: Projects + Project::Archivable

**Files:**
- Create: migration `create_projects`, `app/models/project.rb`, `app/models/project/archivable.rb`
- Modify: `app/models/workspace.rb`
- Test: `test/models/project/archivable_test.rb`, `test/fixtures/projects.yml`; tighten `test/models/current_test.rb` to use real fixtures

**Interfaces:**
- Produces: `workspace.projects`, `project.archive` / `unarchive` / `archived?` / `active?`, scopes `Project.active` / `Project.archived`, `project.deletable?`. Lambda-default shape `belongs_to :workspace` used by all Phase 1+ models via `project`.

- [ ] **Step 1: Migration**

```ruby
# db/migrate/XXXX_create_projects.rb
class CreateProjects < ActiveRecord::Migration[8.1]
  def change
    create_table :projects do |t|
      t.references :workspace, null: false, foreign_key: true
      t.string :name, null: false
      t.string :slug, null: false
      t.string :default_environment, null: false, default: "production"
      t.datetime :archived_at
      t.timestamps
      t.index [ :workspace_id, :slug ], unique: true
    end
  end
end
```

Run: `bin/rails db:migrate`

- [ ] **Step 2: Write failing test**

```ruby
# test/models/project/archivable_test.rb
require "test_helper"

class Project::ArchivableTest < ActiveSupport::TestCase
  test "archive and unarchive round-trip" do
    project = projects(:acme_default)
    assert project.active?

    project.archive
    assert project.archived?
    assert_not project.active?
    assert_includes Project.archived, project
    assert_not_includes Project.active, project

    project.unarchive
    assert project.active?
    assert_includes Project.active, project
  end

  test "archive is idempotent" do
    project = projects(:acme_default)
    project.archive
    first_archived_at = project.archived_at

    project.archive
    assert_equal first_archived_at, project.archived_at
  end
end
```

```yaml
# test/fixtures/projects.yml
acme_default:
  workspace: acme
  name: Default
  slug: default

globex_default:
  workspace: globex
  name: Default
  slug: default
```

- [ ] **Step 3: Run to verify fail**

Run: `bin/rails test test/models/project/archivable_test.rb`
Expected: FAIL — `NameError: uninitialized constant Project`

- [ ] **Step 4: Implement**

```ruby
# app/models/project/archivable.rb
module Project::Archivable
  extend ActiveSupport::Concern

  included do
    scope :active, -> { where(archived_at: nil) }
    scope :archived, -> { where.not(archived_at: nil) }
  end

  def archived?
    archived_at.present?
  end

  def active?
    !archived?
  end

  def archive
    unless archived?
      update! archived_at: Time.current
    end
  end

  def unarchive
    if archived?
      update! archived_at: nil
    end
  end
end
```

```ruby
# app/models/project.rb
class Project < ApplicationRecord
  include Archivable

  belongs_to :workspace

  validates :name, presence: true
  validates :slug, presence: true, uniqueness: { scope: :workspace_id }

  before_validation :assign_slug, on: :create

  def deletable?
    archived?
  end

  private
    def assign_slug
      self.slug ||= name&.parameterize
    end
end
```

Note: `deletable?` becomes `archived? && emails.none?` when `Email` exists (Phase 1) — the Phase 1 plan carries that change.

```ruby
# app/models/workspace.rb (add)
  has_many :projects, dependent: :destroy
```

Tighten `test/models/current_test.rb` to assert with `workspaces(:acme)` / `projects(:acme_default)`.

- [ ] **Step 5: Run, verify pass, commit**

Run: `bin/rails test`
Expected: PASS

```bash
git add -A
git commit -m "feat: projects with archivable lifecycle"
```

---

### Task 6: Controller concerns — SetsCurrentWorkspaceAndProject + AuthorizesCapability

**Files:**
- Create: `app/controllers/concerns/sets_current_workspace_and_project.rb`, `app/controllers/concerns/authorizes_capability.rb`, `app/controllers/dashboards_controller.rb` (minimal landing page to exercise the stack), `app/views/dashboards/show.html.erb`
- Modify: `config/routes.rb` (`root "dashboards#show"`), `app/controllers/application_controller.rb`
- Test: `test/controllers/dashboards_controller_test.rb`, `test/fixtures/sessions.yml`

**Interfaces:**
- Produces: `Current.workspace`/`Current.project` set on every authenticated dashboard request from `session[:workspace_id]`/`session[:project_slug]` (scoped through `Current.user.workspaces` — never unscoped); `authorize_capability!(capability)` → 403 when missing. Consumed by every dashboard controller in later phases.

- [ ] **Step 1: Write failing test**

```yaml
# test/fixtures/sessions.yml
owner:
  user: owner
  ip_address: 127.0.0.1
  user_agent: Minitest

read_only:
  user: read_only
  ip_address: 127.0.0.1
  user_agent: Minitest
```

```ruby
# test/controllers/dashboards_controller_test.rb
require "test_helper"

class DashboardsControllerTest < ActionDispatch::IntegrationTest
  test "requires authentication" do
    get root_url

    assert_redirected_to new_session_url
  end

  test "defaults to the user's first workspace and active project" do
    sign_in_as users(:owner)

    get root_url

    assert_response :success
    assert_select "[data-workspace-slug=?]", "acme"
  end

  test "session workspace_id from another user's workspace is ignored" do
    sign_in_as users(:owner)

    get root_url(workspace_id: workspaces(:globex).id) # attempt via param is a no-op; session-based
    assert_response :success
    assert_select "[data-workspace-slug=?]", "acme"
  end
end
```

Add the sign-in test helper:

```ruby
# test/test_helper.rb (add inside ActiveSupport::TestCase or a new module)
module SignInHelper
  def sign_in_as(user)
    post session_url, params: { email_address: user.email_address, password: "secret123456" }
  end
end

class ActionDispatch::IntegrationTest
  include SignInHelper
end
```

- [ ] **Step 2: Run to verify fail**

Run: `bin/rails test test/controllers/dashboards_controller_test.rb`
Expected: FAIL — no root route / `DashboardsController` missing

- [ ] **Step 3: Implement**

```ruby
# app/controllers/concerns/sets_current_workspace_and_project.rb
module SetsCurrentWorkspaceAndProject
  extend ActiveSupport::Concern

  included do
    before_action :set_current_workspace, :set_current_project
  end

  private
    def set_current_workspace
      Current.workspace = Current.user.workspaces.find_by(id: session[:workspace_id]) ||
        Current.user.workspaces.order(:id).first
    end

    def set_current_project
      if Current.workspace
        Current.project = Current.workspace.projects.active.find_by(slug: session[:project_slug]) ||
          Current.workspace.projects.active.order(:id).first
      end
    end
end
```

```ruby
# app/controllers/concerns/authorizes_capability.rb
module AuthorizesCapability
  extend ActiveSupport::Concern

  private
    def authorize_capability!(capability)
      unless Current.workspace&.capability?(Current.user, capability)
        head :forbidden
      end
    end
end
```

```ruby
# app/controllers/application_controller.rb
class ApplicationController < ActionController::Base
  include Authentication
  include SetsCurrentWorkspaceAndProject
  include AuthorizesCapability

  allow_browser versions: :modern
end
```

```ruby
# app/controllers/dashboards_controller.rb
class DashboardsController < ApplicationController
  def show
  end
end
```

```erb
<%# app/views/dashboards/show.html.erb %>
<main data-workspace-slug="<%= Current.workspace&.slug %>" data-project-slug="<%= Current.project&.slug %>">
  <h1><%= Current.workspace&.name %></h1>
</main>
```

```ruby
# config/routes.rb
root "dashboards#show"
```

Note: `SetsCurrentWorkspaceAndProject` must be skipped by unauthenticated controllers — the generator's `allow_unauthenticated_access` leaves `Current.user` nil, so guard: change `set_current_workspace` first line to run only `if authenticated?` (the concern's before_actions run after `Authentication`'s). Implementation:

```ruby
    def set_current_workspace
      if authenticated?
        Current.workspace = Current.user.workspaces.find_by(id: session[:workspace_id]) ||
          Current.user.workspaces.order(:id).first
      end
    end
```

- [ ] **Step 4: Run, verify pass, commit**

Run: `bin/rails test`
Expected: PASS

```bash
git add -A
git commit -m "feat: workspace/project request context and capability authorization"
```

---

### Task 7: Workspaces controller + switcher

**Files:**
- Create: `app/controllers/workspaces_controller.rb`, `app/controllers/workspaces/switches_controller.rb`, `app/views/workspaces/new.html.erb`, switcher partial `app/views/workspaces/_switcher.html.erb`
- Modify: `config/routes.rb`, dashboard layout/view to render switcher
- Test: `test/controllers/workspaces/switches_controller_test.rb`, `test/controllers/workspaces_controller_test.rb`

**Interfaces:**
- Consumes: `Workspace.create_with_owner` (Task 4).
- Produces: `POST /workspaces/:workspace_id/switch` persisting `session[:workspace_id]`; `WorkspacesController#new/create`.

- [ ] **Step 1: Write failing tests**

```ruby
# test/controllers/workspaces/switches_controller_test.rb
require "test_helper"

class Workspaces::SwitchesControllerTest < ActionDispatch::IntegrationTest
  setup do
    # owner belongs to acme; add a second membership to switch into
    workspaces(:globex).memberships.create!(user: users(:owner), role: "member")
    sign_in_as users(:owner)
  end

  test "switching changes the current workspace" do
    post workspace_switch_url(workspaces(:globex))

    assert_redirected_to root_url
    follow_redirect!
    assert_select "[data-workspace-slug=?]", "globex"
  end

  test "cannot switch to a workspace the user does not belong to" do
    workspaces(:globex).memberships.where(user: users(:owner)).delete_all

    post workspace_switch_url(workspaces(:globex))

    assert_response :not_found
  end
end
```

```ruby
# test/controllers/workspaces_controller_test.rb
require "test_helper"

class WorkspacesControllerTest < ActionDispatch::IntegrationTest
  test "creating a workspace makes the creator its owner and switches to it" do
    sign_in_as users(:owner)

    assert_difference -> { Workspace.count }, +1 do
      post workspaces_url, params: { workspace: { name: "Side Project" } }
    end

    workspace = Workspace.order(:id).last
    assert_equal "owner", workspace.role_for(users(:owner))
    assert_redirected_to root_url
  end
end
```

- [ ] **Step 2: Run to verify fail**

Run: `bin/rails test test/controllers/workspaces_controller_test.rb test/controllers/workspaces/switches_controller_test.rb`
Expected: FAIL — routes undefined

- [ ] **Step 3: Implement**

```ruby
# config/routes.rb (add)
resources :workspaces, only: %i[ new create ] do
  scope module: :workspaces do
    resource :switch, only: :create
  end
end
```

```ruby
# app/controllers/workspaces/switches_controller.rb
class Workspaces::SwitchesController < ApplicationController
  def create
    workspace = Current.user.workspaces.find(params[:workspace_id])
    session[:workspace_id] = workspace.id
    session.delete(:project_slug)
    redirect_to root_url
  end
end
```

(`find` on the scoped association raises `RecordNotFound` → Rails renders 404 in production; in test assert via `assert_response :not_found` with `config.action_dispatch.show_exceptions = :rescuable` default — if the test env raises instead, use `assert_raises(ActiveRecord::RecordNotFound)` form.)

```ruby
# app/controllers/workspaces_controller.rb
class WorkspacesController < ApplicationController
  def new
    @workspace = Workspace.new
  end

  def create
    workspace = Workspace.create_with_owner(owner: Current.user, **workspace_params.to_h.symbolize_keys)
    session[:workspace_id] = workspace.id
    redirect_to root_url
  end

  private
    def workspace_params
      params.expect(workspace: [ :name ])
    end
end
```

```erb
<%# app/views/workspaces/_switcher.html.erb %>
<nav class="flex gap align-center">
  <% Current.user.workspaces.each do |workspace| %>
    <%= button_to workspace.name, workspace_switch_path(workspace),
          class: "btn btn--plain btn--medium#{" btn--current" if workspace == Current.workspace}" %>
  <% end %>
  <%= link_to "New workspace", new_workspace_path, class: "btn btn--secondary btn--medium" %>
</nav>
```

- [ ] **Step 4: Run, verify pass, commit**

Run: `bin/rails test`
Expected: PASS

```bash
git add -A
git commit -m "feat: multi-workspace creation and switcher"
```

---

### Task 8: Invitations

**Files:**
- Create: migration `create_invitations`, `app/models/invitation.rb`, `app/controllers/workspaces/invitations_controller.rb`, `app/controllers/invitations/acceptances_controller.rb`, `app/mailers/invitation_mailer.rb`, views (`workspaces/invitations/new`, `invitations/acceptances/new`, mailer templates)
- Modify: `config/routes.rb`, `app/models/workspace.rb` (`has_many :invitations`)
- Test: `test/models/invitation_test.rb`, `test/controllers/invitations/acceptances_controller_test.rb`, `test/fixtures/invitations.yml`

**Interfaces:**
- Consumes: `authorize_capability! :manage_members` (Task 6), roles list (Task 3).
- Produces: `workspace.invitations.create!(email:, role:)` → `invitation.token` (plaintext, once); `Invitation.find_by_token(token)` (pending only); `invitation.accept(user:)`; `invitation.deliver_later` → `InvitationMailer`. `Invitation.prune_expired` seam consumed by Phase 6.

- [ ] **Step 1: Migration**

```ruby
# db/migrate/XXXX_create_invitations.rb
class CreateInvitations < ActiveRecord::Migration[8.1]
  def change
    create_table :invitations do |t|
      t.references :workspace, null: false, foreign_key: true
      t.references :invited_by, null: false, foreign_key: { to_table: :users }
      t.string :email, null: false
      t.string :role, null: false
      t.string :token_digest, null: false, index: { unique: true }
      t.datetime :expires_at, null: false
      t.datetime :accepted_at
      t.timestamps
    end
  end
end
```

Run: `bin/rails db:migrate`

- [ ] **Step 2: Write failing model test**

```ruby
# test/models/invitation_test.rb
require "test_helper"

class InvitationTest < ActiveSupport::TestCase
  setup do
    Current.session = sessions(:owner)
  end

  test "creating an invitation exposes the plaintext token once and stores a digest" do
    invitation = workspaces(:acme).invitations.create!(email: "new@example.com", role: "member")

    assert invitation.token.present?
    assert_equal Digest::SHA256.hexdigest(invitation.token), invitation.token_digest
    assert_equal users(:owner), invitation.invited_by
    assert invitation.expires_at > 6.days.from_now
  end

  test "find_by_token finds pending invitations only" do
    invitation = workspaces(:acme).invitations.create!(email: "new@example.com", role: "member")

    assert_equal invitation, Invitation.find_by_token(invitation.token)

    invitation.update! accepted_at: Time.current
    assert_nil Invitation.find_by_token(invitation.token)
  end

  test "expired invitations are not findable" do
    invitation = workspaces(:acme).invitations.create!(email: "new@example.com", role: "member")
    invitation.update! expires_at: 1.hour.ago

    assert_nil Invitation.find_by_token(invitation.token)
  end

  test "accept creates a membership with the invited role and stamps accepted_at" do
    invitation = workspaces(:acme).invitations.create!(email: "new@example.com", role: "sender")
    user = User.create!(email_address: "new@example.com",
      password: "secret123456", password_confirmation: "secret123456")

    assert_difference -> { Membership.count }, +1 do
      invitation.accept(user: user)
    end

    assert_equal "sender", workspaces(:acme).role_for(user)
    assert invitation.accepted_at.present?
  end

  test "accept is safe for a user who is already a member" do
    invitation = workspaces(:acme).invitations.create!(email: users(:member).email_address, role: "sender")

    assert_no_difference -> { Membership.count } do
      invitation.accept(user: users(:member))
    end

    assert_equal "member", workspaces(:acme).role_for(users(:member))
  end
end
```

- [ ] **Step 3: Run to verify fail**

Run: `bin/rails test test/models/invitation_test.rb`
Expected: FAIL — `NameError: uninitialized constant Invitation`

- [ ] **Step 4: Implement**

```ruby
# app/models/invitation.rb
class Invitation < ApplicationRecord
  belongs_to :workspace
  belongs_to :invited_by, class_name: "User", default: -> { Current.user }

  scope :pending, -> { where(accepted_at: nil).where(expires_at: Time.current..) }
  scope :expired, -> { where(accepted_at: nil).where(expires_at: ...Time.current) }

  validates :email, presence: true
  validates :role, inclusion: { in: Workspace::Roles::ROLE_CAPABILITIES.keys }

  before_create :generate_token, :set_expiry

  attr_reader :token

  class << self
    def find_by_token(token)
      pending.find_by(token_digest: Digest::SHA256.hexdigest(token.to_s))
    end

    def prune_expired
      expired.in_batches.delete_all
    end
  end

  def accept(user:)
    transaction do
      workspace.memberships.find_or_create_by!(user: user) { |membership| membership.role = role }
      update! accepted_at: Time.current
    end
  end

  def deliver_later
    InvitationMailer.invite(self, token).deliver_later
  end

  private
    def generate_token
      @token = SecureRandom.urlsafe_base64(24)
      self.token_digest = Digest::SHA256.hexdigest(@token)
    end

    def set_expiry
      self.expires_at ||= 7.days.from_now
    end
end
```

```ruby
# app/mailers/invitation_mailer.rb
class InvitationMailer < ApplicationMailer
  def invite(invitation, token)
    @invitation = invitation
    @acceptance_url = new_invitation_acceptance_url(invitation_token: token)
    mail to: invitation.email, subject: "You've been invited to #{invitation.workspace.name} on Departures"
  end
end
```

```erb
<%# app/views/invitation_mailer/invite.html.erb %>
<p><%= @invitation.invited_by.email_address %> invited you to the
  <strong><%= @invitation.workspace.name %></strong> workspace as <%= @invitation.role.humanize.downcase %>.</p>
<p><%= link_to "Accept invitation", @acceptance_url %></p>
<p>This invitation expires on <%= @invitation.expires_at.to_date %>.</p>
```

(Plus a plain-text `invite.text.erb` mirror.)

- [ ] **Step 5: Controllers and routes — write failing acceptance test**

```ruby
# test/controllers/invitations/acceptances_controller_test.rb
require "test_helper"

class Invitations::AcceptancesControllerTest < ActionDispatch::IntegrationTest
  setup do
    Current.session = sessions(:owner)
    @invitation = workspaces(:acme).invitations.create!(email: "new@example.com", role: "member")
    @token = @invitation.token
    Current.reset
  end

  test "a signed-in user accepts directly" do
    sign_in_as users(:outsider)

    assert_difference -> { Membership.count }, +1 do
      post invitation_acceptance_url(invitation_token: @token)
    end

    assert_redirected_to root_url
    assert_equal "member", workspaces(:acme).role_for(users(:outsider))
  end

  test "a new visitor creates an account and accepts in one step" do
    assert_difference -> { User.count } => +1, -> { Membership.count } => +1 do
      post invitation_acceptance_url(invitation_token: @token), params: {
        email_address: "new@example.com", password: "secret123456", password_confirmation: "secret123456" }
    end

    assert_redirected_to root_url
  end

  test "invalid token is not found" do
    post invitation_acceptance_url(invitation_token: "bogus")

    assert_response :not_found
  end
end
```

- [ ] **Step 6: Run to verify fail, then implement controllers + routes**

Run: `bin/rails test test/controllers/invitations/acceptances_controller_test.rb`
Expected: FAIL — route undefined

```ruby
# config/routes.rb (add; also nest invitations under workspaces)
resources :workspaces, only: %i[ new create ] do
  scope module: :workspaces do
    resource :switch, only: :create
    resources :invitations, only: %i[ new create ]
  end
end

resource :invitation_acceptance, only: %i[ new create ], path: "invitations/:invitation_token/acceptance",
  as: :invitation_acceptance, controller: "invitations/acceptances"
```

```ruby
# app/controllers/workspaces/invitations_controller.rb
class Workspaces::InvitationsController < ApplicationController
  before_action :set_workspace
  before_action -> { authorize_capability! :manage_members }

  def new
    @invitation = @workspace.invitations.new
  end

  def create
    invitation = @workspace.invitations.create!(invitation_params)
    invitation.deliver_later
    redirect_to root_url, notice: "Invitation sent to #{invitation.email}"
  end

  private
    def set_workspace
      @workspace = Current.user.workspaces.find(params[:workspace_id])
    end

    def invitation_params
      params.expect(invitation: [ :email, :role ])
    end
end
```

```ruby
# app/controllers/invitations/acceptances_controller.rb
class Invitations::AcceptancesController < ApplicationController
  allow_unauthenticated_access

  before_action :set_invitation

  def new
    @user = User.new(email_address: @invitation.email)
  end

  def create
    if authenticated?
      @invitation.accept(user: Current.user)
    else
      user = User.create!(user_params)
      start_new_session_for user
      @invitation.accept(user: user)
    end

    redirect_to root_url, notice: "Welcome to #{@invitation.workspace.name}"
  end

  private
    def set_invitation
      @invitation = Invitation.find_by_token(params[:invitation_token]) or head :not_found
    end

    def user_params
      params.permit(:email_address, :password, :password_confirmation)
    end
end
```

```erb
<%# app/views/invitations/acceptances/new.html.erb %>
<h1>Join <%= @invitation.workspace.name %></h1>

<% if authenticated? %>
  <%= button_to "Accept invitation", invitation_acceptance_path(invitation_token: params[:invitation_token]),
        class: "btn btn--primary btn--large" %>
<% else %>
  <%= form_with model: @user, url: invitation_acceptance_path(invitation_token: params[:invitation_token]),
        class: "flex flex-column gap" do |form| %>
    <%= form.email_field :email_address, class: "input", required: true %>
    <%= form.password_field :password, class: "input", required: true, placeholder: "Password" %>
    <%= form.password_field :password_confirmation, class: "input", required: true, placeholder: "Confirm password" %>
    <%= form.submit "Create account & join", class: "btn btn--primary btn--medium" %>
  <% end %>
<% end %>
```

(`workspaces/invitations/new.html.erb`: email field + role `input--select` over `Workspace::Roles::ROLE_CAPABILITIES.keys`.)

- [ ] **Step 7: Run, verify pass, commit**

Run: `bin/rails test`
Expected: PASS (also add a capability test: `sign_in_as users(:read_only)` then `post workspace_invitations_url(workspaces(:acme)) …` → `assert_response :forbidden`)

```bash
git add -A
git commit -m "feat: workspace invitations with tokenized acceptance flow"
```

---

### Task 9: ActiveJob workspace context

**Files:**
- Create: `config/initializers/active_job.rb`, `app/jobs/` (uses generated `ApplicationJob`)
- Test: `test/jobs/workspace_context_test.rb`, throwaway test job defined inline in the test

**Interfaces:**
- Produces: every job automatically captures `Current.workspace` at enqueue (GlobalID), restores it around `perform`, and `enqueue_after_transaction_commit = true` app-wide. Later phases never pass workspace into jobs.

- [ ] **Step 1: Write failing test**

```ruby
# test/jobs/workspace_context_test.rb
require "test_helper"

class WorkspaceContextTest < ActiveJob::TestCase
  class ProbeJob < ApplicationJob
    cattr_accessor :seen_workspace

    def perform
      self.class.seen_workspace = Current.workspace
    end
  end

  test "jobs restore the workspace that was current at enqueue time" do
    Current.workspace = workspaces(:acme)
    ProbeJob.perform_later
    Current.reset

    perform_enqueued_jobs

    assert_equal workspaces(:acme), ProbeJob.seen_workspace
  end

  test "jobs enqueued without a workspace run with none" do
    ProbeJob.seen_workspace = :sentinel
    ProbeJob.perform_later

    perform_enqueued_jobs

    assert_nil ProbeJob.seen_workspace
  end
end
```

- [ ] **Step 2: Run to verify fail**

Run: `bin/rails test test/jobs/workspace_context_test.rb`
Expected: FAIL — `seen_workspace` is nil in first test (no capture yet)

- [ ] **Step 3: Implement (patterns §4.5, account → workspace)**

```ruby
# config/initializers/active_job.rb
module DeparturesJobExtensions
  def self.prepended(base)
    base.attr_reader :workspace
  end

  def initialize(...)
    super
    @workspace = Current.workspace
  end

  def serialize
    super.merge("workspace" => @workspace&.to_gid&.to_s)
  end

  def deserialize(job_data)
    super
    if workspace_gid = job_data["workspace"]
      @workspace = GlobalID::Locator.locate(workspace_gid)
    end
  end

  def perform_now
    if workspace.present?
      Current.set(workspace: workspace) { super }
    else
      super
    end
  end
end

Rails.application.config.active_job.enqueue_after_transaction_commit = true

ActiveSupport.on_load(:active_job) do
  prepend DeparturesJobExtensions
end
```

- [ ] **Step 4: Run, verify pass, commit**

Run: `bin/rails test`
Expected: PASS

```bash
git add -A
git commit -m "feat: jobs capture and restore Current.workspace automatically"
```

---

### Task 10: CSS foundation + icon helper

**Files:**
- Create: `app/assets/stylesheets/base.css`, `utilities.css`, `buttons.css`, `inputs.css`; `app/helpers/icons_helper.rb`; initial monochrome SVGs in `app/assets/images/` (`add.svg`, `check.svg`, `close.svg`, `trash.svg`, `pencil.svg`, `search.svg`, `person.svg`, `arrow-left.svg`, `caret-down.svg`, `copy-paste.svg`)
- Modify: `app/views/layouts/application.html.erb` (header with workspace switcher, `#main` grid), delete/replace `app/assets/stylesheets/application.css` content with layer declarations + imports
- Test: `test/helpers/icons_helper_test.rb`

**Directives:** follow style-guide.md exactly — this task creates the token system every later view consumes. `@layer reset, base, components, modules, utilities` order declared first; OKLCH tokens; logical properties; light + dark.

- [ ] **Step 1: Write failing helper test**

```ruby
# test/helpers/icons_helper_test.rb
require "test_helper"

class IconsHelperTest < ActionView::TestCase
  test "icon_tag renders a masked, aria-hidden span" do
    html = icon_tag("check")

    assert_match(/class="icon"/, html)
    assert_match(/aria-hidden="true"/, html)
    assert_match(/--svg: url\(.*check.*\.svg\)/, html)
  end

  test "icon_tag merges extra classes" do
    assert_match(/class="icon txt-subtle"/, icon_tag("check", class: "txt-subtle"))
  end
end
```

- [ ] **Step 2: Run to verify fail**

Run: `bin/rails test test/helpers/icons_helper_test.rb`
Expected: FAIL — `icon_tag` undefined

- [ ] **Step 3: Implement helper**

```ruby
# app/helpers/icons_helper.rb
module IconsHelper
  def icon_tag(name, **options)
    css_classes = [ "icon", options.delete(:class) ].compact.join(" ")
    svg_style = "--svg: url(#{image_path("#{name}.svg")})"
    style = [ svg_style, options.delete(:style) ].compact.join("; ")

    tag.span nil, class: css_classes, style: style, aria: { hidden: true }, **options
  end
end
```

- [ ] **Step 4: Create the stylesheets**

```css
/* app/assets/stylesheets/base.css */
@layer reset, base, components, modules, utilities;

@layer base {
  :root {
    /* neutrals + semantic colors (OKLCH, style-guide.md) */
    --lch-black: 0% 0 0;
    --lch-white: 100% 0 0;
    --color-ink: oklch(21% 0.01 260);
    --color-ink-light: oklch(45% 0.015 260);
    --color-ink-lighter: oklch(60% 0.012 260);
    --color-ink-inverted: oklch(98% 0 0);
    --color-canvas: oklch(98.5% 0.002 260);
    --color-surface: oklch(100% 0 0);
    --color-border: oklch(92.8% 0.006 264);
    --color-border-strong: oklch(70.7% 0.022 261);
    --color-link: oklch(55% 0.18 260);
    --color-positive: oklch(58% 0.15 150);
    --color-negative: oklch(58% 0.2 25);
    --color-highlight: oklch(90% 0.15 95);

    /* typography */
    --font-sans: -apple-system, BlinkMacSystemFont, "Segoe UI", "Noto Sans", Helvetica, Arial, sans-serif;
    --font-mono: ui-monospace, monospace;
    --text-x-small: 0.75rem;
    --text-small: 0.85rem;
    --text-normal: 1rem;
    --text-medium: 1.1rem;
    --text-large: 1.5rem;

    /* spacing */
    --inline-space: 1ch;
    --inline-space-half: 0.5ch;
    --block-space: 1rem;
    --block-space-half: 0.5rem;
    --block-space-double: 2rem;
    --main-padding: clamp(1ch, 3vw, 3ch);
    --main-width: 1400px;

    /* focus */
    --focus-ring-color: var(--color-link);
    --focus-ring-size: 2px;
  }

  html[data-theme="dark"] {
    --color-ink: oklch(93% 0.005 260);
    --color-ink-light: oklch(72% 0.01 260);
    --color-ink-lighter: oklch(58% 0.012 260);
    --color-ink-inverted: oklch(18% 0.01 260);
    --color-canvas: oklch(18% 0.012 260);
    --color-surface: oklch(23% 0.012 260);
    --color-border: oklch(32% 0.012 260);
    --color-border-strong: oklch(45% 0.02 260);
  }

  @media (prefers-color-scheme: dark) {
    html:not([data-theme]) {
      --color-ink: oklch(93% 0.005 260);
      --color-ink-light: oklch(72% 0.01 260);
      --color-ink-lighter: oklch(58% 0.012 260);
      --color-ink-inverted: oklch(18% 0.01 260);
      --color-canvas: oklch(18% 0.012 260);
      --color-surface: oklch(23% 0.012 260);
      --color-border: oklch(32% 0.012 260);
      --color-border-strong: oklch(45% 0.02 260);
    }
  }

  body {
    background-color: var(--color-canvas);
    color: var(--color-ink);
    font-family: var(--font-sans);
    line-height: 1.375;
    -webkit-font-smoothing: antialiased;
    margin: 0;
  }

  :focus-visible {
    outline: var(--focus-ring-size) solid var(--focus-ring-color);
    outline-offset: 2px;
  }

  .icon {
    background-color: currentColor;
    block-size: var(--icon-size, 1em);
    display: inline-block;
    inline-size: var(--icon-size, 1em);
    mask-image: var(--svg);
    mask-position: center;
    mask-repeat: no-repeat;
    mask-size: var(--icon-size, 1em);
    vertical-align: -0.125em;
  }

  @media (prefers-reduced-motion: reduce) {
    *, *::before, *::after {
      animation-duration: 0.01ms !important;
      transition-duration: 0.01ms !important;
    }
  }
}
```

```css
/* app/assets/stylesheets/utilities.css */
@layer utilities {
  .flex { display: flex; }
  .flex-column { flex-direction: column; }
  .flex-wrap { flex-wrap: wrap; }
  .flex-1 { flex: 1; }
  .gap { gap: var(--block-space); }
  .gap-half { gap: var(--block-space-half); }
  .align-center { align-items: center; }
  .justify-space-between { justify-content: space-between; }
  .full-width { inline-size: 100%; }
  .center { margin-inline: auto; }

  .pad { padding: var(--block-space) var(--inline-space); }
  .pad-block { padding-block: var(--block-space); }
  .pad-inline { padding-inline: var(--inline-space); }
  .margin-block { margin-block: var(--block-space); }
  .margin-block-half { margin-block: var(--block-space-half); }
  .margin-none { margin: 0; }

  .txt-x-small { font-size: var(--text-x-small); }
  .txt-small { font-size: var(--text-small); }
  .txt-medium { font-size: var(--text-medium); }
  .txt-large { font-size: var(--text-large); }
  .txt-subtle { color: var(--color-ink-lighter); }
  .txt-negative { color: var(--color-negative); }
  .txt-positive { color: var(--color-positive); }
  .font-weight-bold { font-weight: 700; }

  .for-screen-reader {
    block-size: 1px;
    clip-path: inset(50%);
    inline-size: 1px;
    overflow: hidden;
    position: absolute;
    white-space: nowrap;
  }
}
```

```css
/* app/assets/stylesheets/buttons.css */
@layer components {
  .btn {
    --btn-background: var(--color-surface);
    --btn-color: var(--color-ink);
    --btn-border-color: var(--color-border-strong);
    --btn-padding: 0.5em 1em;

    background-color: var(--btn-background);
    border: 1px solid var(--btn-border-color);
    border-radius: 0.5em;
    color: var(--btn-color);
    cursor: pointer;
    display: inline-flex;
    align-items: center;
    gap: var(--inline-space-half);
    font: inherit;
    padding: var(--btn-padding);
    text-decoration: none;
    transition: 100ms ease-out;
    transition-property: background-color, border-color, box-shadow, filter;
  }

  .btn:hover { filter: brightness(0.97); }
  .btn:disabled { cursor: not-allowed; opacity: 0.5; pointer-events: none; }

  .btn--plain { --btn-background: transparent; --btn-border-color: transparent; }
  .btn--primary {
    --btn-background: var(--color-link);
    --btn-border-color: var(--color-link);
    --btn-color: var(--color-ink-inverted);
  }
  .btn--secondary {
    --btn-background: var(--color-positive);
    --btn-border-color: var(--color-positive);
    --btn-color: var(--color-ink-inverted);
  }
  .btn--destroy {
    --btn-background: var(--color-negative);
    --btn-border-color: var(--color-negative);
    --btn-color: var(--color-ink-inverted);
  }
  .btn--medium { font-size: var(--text-normal); }
  .btn--large { font-size: var(--text-medium); }
  .btn--current { --btn-border-color: var(--color-link); }
}
```

```css
/* app/assets/stylesheets/inputs.css */
@layer components {
  .input {
    --input-background: transparent;
    --input-border-color: var(--color-border-strong);
    --input-padding: 0.5em 0.8em;

    background-color: var(--input-background);
    border: 1px solid var(--input-border-color);
    border-radius: 0.5em;
    color: var(--color-ink);
    font: inherit;
    font-size: max(16px, 1em);
    inline-size: 100%;
    padding: var(--input-padding);
    resize: none;
  }

  .input:focus {
    outline: var(--focus-ring-size) solid var(--focus-ring-color);
    outline-offset: -1px;
  }

  .input:disabled { cursor: not-allowed; opacity: 0.5; pointer-events: none; }

  .input--select {
    appearance: none;
    background-image: url("caret-down.svg");
    background-position: right 0.5em center;
    background-repeat: no-repeat;
    background-size: 1em;
    padding-inline-end: 1.8em;
  }
}
```

Icon SVGs: monochrome, `viewBox="0 0 24 24"`, no width/height, single path (style-guide "SVG File Requirements"). Example:

```xml
<!-- app/assets/images/check.svg -->
<svg viewBox="0 0 24 24" xmlns="http://www.w3.org/2000/svg">
  <path d="M9 16.2 4.8 12l-1.4 1.4L9 19 21 7l-1.4-1.4z"/>
</svg>
```

Layout:

```erb
<%# app/views/layouts/application.html.erb — body content %>
<body>
  <% if authenticated? %>
    <header class="flex align-center justify-space-between pad">
      <%= link_to "Departures", root_path, class: "font-weight-bold txt-medium" %>
      <%= render "workspaces/switcher" %>
      <%= button_to "Sign out", session_path, method: :delete, class: "btn btn--plain btn--medium" %>
    </header>
  <% end %>
  <main id="main" class="center pad" style="max-inline-size: var(--main-width);">
    <%= yield %>
  </main>
</body>
```

- [ ] **Step 5: Verify visually and in tests**

Run: `bin/rails test` → PASS.
Run: `bin/dev`, open `http://localhost:3000`, check header/switcher/forms in **both** light and dark (`document.documentElement.dataset.theme = "dark"` in console).

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "feat: CSS foundation with OKLCH tokens, buttons, inputs, and icon helper"
```

---

### Task 11: Phase wrap-up

**Files:**
- Modify: `README.md` (document `OPEN_REGISTRATION` in Getting started)

- [ ] **Step 1: Full verification**

```bash
bin/rubocop -a
bin/rails test
```

Expected: 0 offenses, all tests pass. Fix anything that surfaces.

- [ ] **Step 2: Manual smoke**

`bin/dev` → register first user (works) → note second registration blocked → create second workspace → switch → invite an email as `sender` → open the logged invitation URL in a private window → create account → land in the workspace with sender role.

- [ ] **Step 3: README + commit**

Add to README Getting started: "Registration is open only for the first user; set `OPEN_REGISTRATION=1` to allow more sign-ups."

```bash
git add -A
git commit -m "chore: phase 0 wrap-up — rubocop, docs"
```

---

## Verification (phase-level)

- `bin/rails test` green; `bin/rubocop` clean.
- Roadmap Phase 0 test list covered: registration gating ✓ (Task 2), invitation accept new + existing user ✓ (Task 8), workspace switching ✓ (Task 7), cross-workspace 404s ✓ (Tasks 6/7), 6×6 role capability matrix ✓ (Task 3).
- Manual smoke per Task 11.
- Before starting Phase 1: author `docs/plans/phase-1-send-domain-plan.md` from the master plan's Phase 1 map.
