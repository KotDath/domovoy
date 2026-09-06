import 'package:domovoy/features/prompt/data/chat_completions_provider_profile.dart';
import 'package:domovoy/features/prompt/domain/agent.dart';
import 'package:domovoy/features/reasoning/domain/four_house_puzzle.dart';
import 'package:domovoy/features/reasoning/domain/reasoning_prompts.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const task = fourHousePresetTask;

  group('Day 3 prompt transformations', () {
    test('direct prompt is the trimmed task with no strategy suffix', () {
      const raw = '  same task  ';
      expect(buildDirectPrompt(raw), 'same task');
      expect(buildDirectPrompt(raw), isNot(contains('---')));
      expect(buildDirectPrompt(raw), isNot(contains('шаг')));
    });

    test(
      'step-by-step prompt keeps the task and asks to verify the conclusion',
      () {
        final prompt = buildStepByStepPrompt(task);
        expect(prompt, startsWith(task.trim()));
        expect(prompt, contains('по шагам'));
        expect(prompt, contains('сверьте заключение'));
      },
    );

    test(
      'prompt builder asks for a self-contained uniqueness-checking prompt',
      () {
        final prompt = buildPromptBuilderPrompt(task);
        expect(prompt, contains(task.trim()));
        expect(prompt, contains('самодостаточный промпт-решатель'));
        expect(prompt, contains('единственность'));
        expect(prompt, contains('только текст промпта'));
      },
    );

    test(
      'generated solver keeps generated instructions and the original snapshot',
      () {
        const generated = 'Проверьте все условия и единственность.';
        final prompt = buildGeneratedSolverPrompt(
          generatedInstructions: generated,
          originalTask: task,
        );
        expect(prompt, contains(generated));
        expect(prompt, contains(task.trim()));
        expect(prompt, contains('Инструкции решателя:'));
        expect(prompt, contains('Исходная задача'));
      },
    );

    test(
      'expert group asks labeled analyst, engineer, critic, then synthesis',
      () {
        final prompt = buildExpertGroupPrompt(task);
        expect(prompt, startsWith(task.trim()));
        expect(prompt, contains('## Аналитик'));
        expect(prompt, contains('## Инженер'));
        expect(prompt, contains('## Критик'));
        expect(prompt, contains('синтез'));
      },
    );

    test('every Day 3 input disables thinking and omits reasoning effort', () {
      final inputs = <AgentInput>[
        buildDirectInput(task),
        buildStepByStepInput(task),
        buildPromptBuilderInput(task),
        buildGeneratedSolverInput(
          generatedInstructions: 'solver',
          originalTask: task,
        ),
        buildExpertGroupInput(task),
      ];
      final profile = ChatCompletionsProviderProfile.deepSeekV4Flash();
      for (final input in inputs) {
        expect(input.thinking, ThinkingMode.disabled);
        expect(input.control, isNull);
        final body = profile.requestBody(input);
        expect(body['thinking'], const <String, String>{'type': 'disabled'});
        expect(body.containsKey('reasoning_effort'), isFalse);
      }
    });
  });

  group('four-house reference solver', () {
    test('preset has exactly the documented unique four-house grid', () {
      final reference = evaluateFourHouseReference();
      expect(reference.solutions, hasLength(1));
      expect(reference.isUnique, isTrue);
      expect(reference.uniqueGrid, documentedFourHouseSolution);
      expect(fourHouseReference.uniqueGrid, documentedFourHouseSolution);
    });

    test('unique grid satisfies every clue and one-to-one categories', () {
      final grid = evaluateFourHouseReference().uniqueGrid;
      expect(grid.hasUniqueCategories, isTrue);
      expect(grid.residents.toSet(), HouseResident.values.toSet());
      expect(grid.drinks.toSet(), HouseDrink.values.toSet());
      expect(grid.pets.toSet(), HousePet.values.toSet());
      expect(grid.clueCoffeeLeftOfAnna, isTrue);
      expect(grid.clueGlebLeftOfJuice, isTrue);
      expect(grid.clueParrotLeftOfWater, isTrue);
      expect(grid.clueFishLeftOfBoris, isTrue);
      expect(grid.clueDogLeftOfGleb, isTrue);
      expect(grid.clueAnnaLeftOfTea, isTrue);
      expect(grid.satisfiesAllClues, isTrue);
      expect(grid.houseOfResident(HouseResident.vera), 0);
      expect(grid.houseOfDrink(HouseDrink.coffee), 0);
      expect(grid.houseOfPet(HousePet.parrot), 0);
      expect(grid.houseOfResident(HouseResident.anna), 1);
      expect(grid.houseOfDrink(HouseDrink.water), 1);
      expect(grid.houseOfPet(HousePet.dog), 1);
      expect(grid.houseOfResident(HouseResident.gleb), 2);
      expect(grid.houseOfDrink(HouseDrink.tea), 2);
      expect(grid.houseOfPet(HousePet.fish), 2);
      expect(grid.houseOfResident(HouseResident.boris), 3);
      expect(grid.houseOfDrink(HouseDrink.juice), 3);
      expect(grid.houseOfPet(HousePet.cat), 3);
    });

    test('edited task is not treated as the built-in preset', () {
      expect(isFourHousePreset(fourHousePresetTask), isTrue);
      expect(isFourHousePreset(' $fourHousePresetTask \n'), isTrue);
      expect(isFourHousePreset('${fourHousePresetTask}x'), isFalse);
    });
  });
}
