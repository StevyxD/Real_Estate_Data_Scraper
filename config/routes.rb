Rails.application.routes.draw do
  # Define your application routes per the DSL in https://guides.rubyonrails.org/routing.html

  # Reveal health status on /up that returns 200 if the app boots with no exceptions, otherwise 500.
  # Can be used by load balancers and uptime monitors to verify that the app is live.
  get "up" => "rails/health#show", as: :rails_health_check

  # Render dynamic PWA files from app/views/pwa/* (remember to link manifest in application.html.erb)
  # get "manifest" => "rails/pwa#manifest", as: :pwa_manifest
  # get "service-worker" => "rails/pwa#service_worker", as: :pwa_service_worker

  resources :documents, only: %i[index show]

  # Live scrape activity + recently scraped documents.
  get "dashboard", to: "dashboard#index", as: :dashboard

  # Mumbai property search → queues a scrape.
  get  "search", to: "searches#new",    as: :search
  post "search", to: "searches#create"

  # Kharghar bulk range → queues a scrape for every property no. in [from..to].
  get  "kharghar", to: "kharghar_scrapes#new",    as: :kharghar_scrape
  post "kharghar", to: "kharghar_scrapes#create"

  # Defines the root path route ("/")
  root "documents#index"
end
