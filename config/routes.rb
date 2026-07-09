Rails.application.routes.draw do
  resource :session
  resource :registration, only: %i[ new create ]
  resources :passwords, param: :token
  resources :workspaces, only: %i[ new create ] do
    scope module: :workspaces do
      resource :switch, only: :create
      resources :invitations, only: %i[ new create ]
    end
  end

  resource :invitation_acceptance, only: %i[ new create ], path: "invitations/:invitation_token/acceptance",
    as: :invitation_acceptance, controller: "invitations/acceptances"

  resource :activity, only: :show, controller: "activity"
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
