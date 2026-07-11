Rails.application.routes.draw do
  resource :session
  resource :challenge, only: %i[ new create ], controller: "sessions/challenges"
  resources :sessions, only: %i[ index destroy ], as: :user_sessions
  resource :other_sessions, only: :destroy, controller: "other_sessions"
  resource :registration, only: %i[ new create ]
  resources :passwords, param: :token
  scope module: :users do
    resource :two_factor, only: %i[ new create destroy ]
    resource :recovery_codes, only: :create
  end
  resources :workspaces, only: %i[ new create edit update ] do
    scope module: :workspaces do
      resource :switch, only: :create
      resources :invitations, only: %i[ new create ]
    end
  end

  resource :invitation_acceptance, only: %i[ new create ], path: "invitations/:invitation_token/acceptance",
    as: :invitation_acceptance, controller: "invitations/acceptances"

  resource :activity, only: :show, controller: "activity"

  resources :emails, only: %i[ index show ] do
    member do
      get :preview
      get :raw
    end
    scope module: :emails do
      resource :resend, only: :create
    end
  end

  resources :suppressions, only: %i[ index create destroy ]

  resources :domains, only: %i[ index create destroy ] do
    scope module: :domains do
      resource :check, only: :create
    end
  end

  resources :sources, only: %i[ index new create edit update ] do
    scope module: :sources do
      resource :quota_sync, only: :create
    end
  end

  resources :webhook_endpoints

  resources :templates, except: :show

  resources :api_keys, only: %i[ index new create destroy ] do
    scope module: :api_keys do
      resource :rotation, only: :create
    end
  end

  resource :onboarding, only: :show do
    scope module: :onboardings do
      resource :completion, only: :create
    end
  end

  resources :bounces, only: :index
  scope module: :bounces, path: :bounces, as: :bounces do
    resource :retry, only: :create
  end

  resources :test_emails, only: %i[ new create ]

  resources :exports, only: :show
  # Define your application routes per the DSL in https://guides.rubyonrails.org/routing.html

  namespace :api do
    resources :emails, only: %i[ index create ]
  end

  post "api/webhooks/ses/:webhook_token", to: "webhooks/ses#create", as: :ses_webhooks

  # Reveal health status on /up that returns 200 if the app boots with no exceptions, otherwise 500.
  # Can be used by load balancers and uptime monitors to verify that the app is live.
  get "up" => "rails/health#show", as: :rails_health_check

  # Render dynamic PWA files from app/views/pwa/* (remember to link manifest in application.html.erb)
  # get "manifest" => "rails/pwa#manifest", as: :pwa_manifest
  # get "service-worker" => "rails/pwa#service_worker", as: :pwa_service_worker

  # Defines the root path route ("/")
  root "dashboards#show"
end
