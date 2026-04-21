require "test_helper"
require "savings_calculator"

class SavingsCalculatorTest < Minitest::Test
  def test_savings_is_kwh_times_price
    calc = SavingsCalculator.new(price_eur_per_kwh: 0.32)
    assert_in_delta 0.32, calc.savings_eur(1_000.0)
    assert_in_delta 0.0,  calc.savings_eur(0.0)
    assert_in_delta 0.08, calc.savings_eur(250.0)
  end

  def test_negative_energy_yields_zero_savings
    calc = SavingsCalculator.new(price_eur_per_kwh: 0.32)
    assert_in_delta 0.0, calc.savings_eur(-50.0)
  end
end
