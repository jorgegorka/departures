class SourcesController < ApplicationController
  include RequiresProject
  allow_unonboarded_access

  skip_before_action :require_project, only: :index
  before_action -> { authorize_capability! :manage_domains }, except: :index
  before_action :set_source, only: %i[ edit update ]

  def index
    if Current.project
      @sources = Current.project.sources.order(:environment)
    end
  end

  def new
    @source = Current.project.sources.new
  end

  def create
    @source = Current.project.sources.new(source_params)

    if @source.save
      redirect_to sources_path, notice: "Source added."
    else
      render :new, status: :unprocessable_entity
    end
  end

  def edit
  end

  def update
    if @source.update(source_params)
      redirect_to sources_path, notice: "Source updated."
    else
      render :edit, status: :unprocessable_entity
    end
  end

  private
    def set_source
      @source = Current.project.sources.find(params[:id])
    end

    def source_params
      params.require(:source).permit(:name, :environment, :region, :default_from,
        :configuration_set, :retention_days, :aws_access_key_id, :aws_secret_access_key)
        .tap do |permitted|
          %i[ aws_access_key_id aws_secret_access_key ].each do |credential|
            if permitted[credential].blank?
              permitted.delete(credential)
            end
          end
        end
    end
end
