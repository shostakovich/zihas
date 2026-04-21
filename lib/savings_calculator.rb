class SavingsCalculator
  def initialize(price_eur_per_kwh:)
    @price = price_eur_per_kwh
  end

  def savings_eur(energy_wh)
    return 0.0 if energy_wh.nil? || energy_wh < 0
    (energy_wh / 1000.0) * @price
  end
end
