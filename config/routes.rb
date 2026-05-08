# Plugin's routes
# See: http://guides.rubyonrails.org/routing.html

resources :recurring_tasks, except: [:index]

get 'admin/recurring_tasks', to: 'admin_recurring_tasks#index', as: :admin_recurring_tasks
