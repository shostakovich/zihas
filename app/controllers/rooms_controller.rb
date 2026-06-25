# app/controllers/rooms_controller.rb
class RoomsController < ApplicationController
  before_action :set_room, only: %i[edit update destroy]

  def index = (@rooms = Room.order(:name))
  def new   = (@room = Room.new)
  def edit; end

  def create
    @room = Room.new(room_params)
    if @room.save
      redirect_to rooms_url, notice: "Raum angelegt."
    else
      render :new, status: :unprocessable_entity
    end
  end

  def update
    if @room.update(room_params)
      redirect_to rooms_url, notice: "Raum aktualisiert."
    else
      render :edit, status: :unprocessable_entity
    end
  end

  def destroy
    @room.destroy
    redirect_to rooms_url, notice: "Raum gelöscht."
  end

  private

  def set_room    = (@room = Room.find(params[:id]))
  def room_params = params.require(:room).permit(:name)
end
