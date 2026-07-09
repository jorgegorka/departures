class TemplatesController < ApplicationController
  include RequiresProject

  skip_before_action :require_project, only: :index
  before_action -> { authorize_capability! :manage_templates }, except: :index
  before_action :set_template, only: %i[ edit update destroy ]

  def index
    if Current.project
      @templates = Current.project.templates.order(:slug)
    end
  end

  def new
    @template = Current.project.templates.new
  end

  def create
    @template = Current.project.templates.new(template_params)

    if @template.save
      redirect_to templates_path, notice: "Template created."
    else
      render :new, status: :unprocessable_entity
    end
  end

  def edit
  end

  def update
    if @template.update(template_params)
      redirect_to templates_path, notice: "Template updated."
    else
      render :edit, status: :unprocessable_entity
    end
  end

  def destroy
    @template.destroy
    redirect_to templates_path, notice: "Template deleted."
  end

  private
    def set_template
      @template = Current.project.templates.find(params[:id])
    end

    def template_params
      params.require(:template).permit(:name, :slug, :subject, :html_body, :text_body)
    end
end
