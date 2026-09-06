import '../../prompt/domain/agent.dart';
import 'chat_model_profile.dart';

sealed class EstimatedCost {
  const EstimatedCost();
}

final class ExactEstimatedCost extends EstimatedCost {
  const ExactEstimatedCost({
    required this.amount,
    required this.currency,
    required this.pricing,
  });

  final double amount;
  final String currency;
  final TokenPricing pricing;
}

final class RangedEstimatedCost extends EstimatedCost {
  const RangedEstimatedCost({
    required this.minimum,
    required this.maximum,
    required this.currency,
    required this.pricing,
  });

  final double minimum;
  final double maximum;
  final String currency;
  final TokenPricing pricing;
}

final class ZeroProviderFeeCost extends EstimatedCost {
  const ZeroProviderFeeCost({required this.pricing});

  final TokenPricing pricing;
}

final class UnavailableEstimatedCost extends EstimatedCost {
  const UnavailableEstimatedCost({this.pricing});

  final TokenPricing? pricing;
}

EstimatedCost estimateProviderCost({
  required TokenPricing? pricing,
  required AgentTokenUsage? usage,
}) {
  if (pricing == null) {
    return const UnavailableEstimatedCost();
  }
  if (pricing.zeroProviderFee) {
    return ZeroProviderFeeCost(pricing: pricing);
  }
  final outputRate = pricing.outputPerMillion;
  final completion = usage?.completionTokens;
  if (outputRate == null || completion == null) {
    return UnavailableEstimatedCost(pricing: pricing);
  }
  final hitTokens = usage?.cacheHitPromptTokens;
  final missTokens = usage?.cacheMissPromptTokens;
  final hitRate = pricing.cacheHitInputPerMillion;
  final missRate = pricing.cacheMissInputPerMillion;
  if (hitTokens != null &&
      missTokens != null &&
      hitRate != null &&
      missRate != null) {
    final amount =
        _perMillion(hitTokens, hitRate) +
        _perMillion(missTokens, missRate) +
        _perMillion(completion, outputRate);
    return ExactEstimatedCost(
      amount: amount,
      currency: pricing.currency,
      pricing: pricing,
    );
  }
  final prompt = usage?.promptTokens;
  if (prompt == null || hitRate == null || missRate == null) {
    return UnavailableEstimatedCost(pricing: pricing);
  }
  final lowRate = hitRate < missRate ? hitRate : missRate;
  final highRate = hitRate > missRate ? hitRate : missRate;
  final output = _perMillion(completion, outputRate);
  final minimum = _perMillion(prompt, lowRate) + output;
  final maximum = _perMillion(prompt, highRate) + output;
  if (minimum == maximum) {
    return ExactEstimatedCost(
      amount: minimum,
      currency: pricing.currency,
      pricing: pricing,
    );
  }
  return RangedEstimatedCost(
    minimum: minimum,
    maximum: maximum,
    currency: pricing.currency,
    pricing: pricing,
  );
}

double _perMillion(int tokens, double rate) => tokens / 1000000 * rate;

String formatCurrencyAmount(String currency, double amount) {
  final symbol = currency.toUpperCase() == 'USD' ? r'$' : '$currency ';
  if (amount == 0) {
    return '${symbol}0';
  }
  final abs = amount.abs();
  final digits = abs >= 0.01 ? 4 : 6;
  return '$symbol${amount.toStringAsFixed(digits)}';
}

String formatEstimatedCost(EstimatedCost cost) {
  switch (cost) {
    case ExactEstimatedCost(:final amount, :final currency, :final pricing):
      return '${formatCurrencyAmount(currency, amount)} '
          '(оценка на ${formatPricingDate(pricing.effectiveDate)})';
    case RangedEstimatedCost(
      :final minimum,
      :final maximum,
      :final currency,
      :final pricing,
    ):
      return '${formatCurrencyAmount(currency, minimum)}–'
          '${formatCurrencyAmount(currency, maximum)} '
          '(оценка на ${formatPricingDate(pricing.effectiveDate)}, '
          'границы cache-hit/cache-miss)';
    case ZeroProviderFeeCost():
      return r'$0 (без платы провайдеру; железо и энергия не измерены)';
    case UnavailableEstimatedCost():
      return 'недоступно';
  }
}
