import 'package:flutter/foundation.dart';

enum HouseResident { anna, boris, vera, gleb }

enum HouseDrink { tea, coffee, juice, water }

enum HousePet { cat, dog, fish, parrot }

const String fourHousePresetTask =
    'Четыре дома стоят в ряд слева направо и пронумерованы 1, 2, 3 и 4.\n'
    'В каждом доме живёт ровно один житель, пьёт ровно один напиток и держит ровно одно домашнее животное.\n'
    'Каждый житель, каждый напиток и каждое животное встречаются ровно один раз.\n'
    'Жители: Анна, Борис, Вера, Глеб.\n'
    'Напитки: чай, кофе, сок, вода.\n'
    'Животные: кошка, собака, рыбка, попугай.\n'
    '\n'
    'Известно:\n'
    '1. Тот, кто пьёт кофе, живёт сразу слева от Анны.\n'
    '2. Глеб живёт сразу слева от того, кто пьёт сок.\n'
    '3. Хозяин попугая живёт сразу слева от того, кто пьёт воду.\n'
    '4. Хозяин рыбки живёт сразу слева от Бориса.\n'
    '5. Хозяин собаки живёт где-то слева от Глеба.\n'
    '6. Анна живёт где-то слева от того, кто пьёт чай.\n'
    '\n'
    'Определите для каждого дома жителя, напиток и животное.';

String normalizeFourHouseTask(String task) => task.trim();

bool isFourHousePreset(String task) =>
    normalizeFourHouseTask(task) == normalizeFourHouseTask(fourHousePresetTask);

String houseResidentLabel(HouseResident resident) => switch (resident) {
  HouseResident.anna => 'Анна',
  HouseResident.boris => 'Борис',
  HouseResident.vera => 'Вера',
  HouseResident.gleb => 'Глеб',
};

String houseDrinkLabel(HouseDrink drink) => switch (drink) {
  HouseDrink.tea => 'чай',
  HouseDrink.coffee => 'кофе',
  HouseDrink.juice => 'сок',
  HouseDrink.water => 'вода',
};

String housePetLabel(HousePet pet) => switch (pet) {
  HousePet.cat => 'кошка',
  HousePet.dog => 'собака',
  HousePet.fish => 'рыбка',
  HousePet.parrot => 'попугай',
};

@immutable
final class FourHouseGrid {
  FourHouseGrid({
    required List<HouseResident> residents,
    required List<HouseDrink> drinks,
    required List<HousePet> pets,
  }) : residents = List<HouseResident>.unmodifiable(residents),
       drinks = List<HouseDrink>.unmodifiable(drinks),
       pets = List<HousePet>.unmodifiable(pets) {
    if (residents.length != 4 || drinks.length != 4 || pets.length != 4) {
      throw ArgumentError('A four-house grid needs four assignments.');
    }
  }

  final List<HouseResident> residents;
  final List<HouseDrink> drinks;
  final List<HousePet> pets;

  int houseOfResident(HouseResident resident) => residents.indexOf(resident);

  int houseOfDrink(HouseDrink drink) => drinks.indexOf(drink);

  int houseOfPet(HousePet pet) => pets.indexOf(pet);

  bool get hasUniqueCategories =>
      residents.toSet().length == 4 &&
      drinks.toSet().length == 4 &&
      pets.toSet().length == 4;

  bool get clueCoffeeLeftOfAnna {
    final anna = houseOfResident(HouseResident.anna);
    final coffee = houseOfDrink(HouseDrink.coffee);
    return anna >= 0 && coffee >= 0 && coffee == anna - 1;
  }

  bool get clueGlebLeftOfJuice {
    final gleb = houseOfResident(HouseResident.gleb);
    final juice = houseOfDrink(HouseDrink.juice);
    return gleb >= 0 && juice >= 0 && gleb == juice - 1;
  }

  bool get clueParrotLeftOfWater {
    final parrot = houseOfPet(HousePet.parrot);
    final water = houseOfDrink(HouseDrink.water);
    return parrot >= 0 && water >= 0 && parrot == water - 1;
  }

  bool get clueFishLeftOfBoris {
    final fish = houseOfPet(HousePet.fish);
    final boris = houseOfResident(HouseResident.boris);
    return fish >= 0 && boris >= 0 && fish == boris - 1;
  }

  bool get clueDogLeftOfGleb {
    final dog = houseOfPet(HousePet.dog);
    final gleb = houseOfResident(HouseResident.gleb);
    return dog >= 0 && gleb >= 0 && dog < gleb;
  }

  bool get clueAnnaLeftOfTea {
    final anna = houseOfResident(HouseResident.anna);
    final tea = houseOfDrink(HouseDrink.tea);
    return anna >= 0 && tea >= 0 && anna < tea;
  }

  bool get satisfiesAllClues =>
      clueCoffeeLeftOfAnna &&
      clueGlebLeftOfJuice &&
      clueParrotLeftOfWater &&
      clueFishLeftOfBoris &&
      clueDogLeftOfGleb &&
      clueAnnaLeftOfTea;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is FourHouseGrid &&
          listEquals(other.residents, residents) &&
          listEquals(other.drinks, drinks) &&
          listEquals(other.pets, pets);

  @override
  int get hashCode => Object.hash(
    Object.hashAll(residents),
    Object.hashAll(drinks),
    Object.hashAll(pets),
  );
}

final FourHouseGrid documentedFourHouseSolution = FourHouseGrid(
  residents: const [
    HouseResident.vera,
    HouseResident.anna,
    HouseResident.gleb,
    HouseResident.boris,
  ],
  drinks: const [
    HouseDrink.coffee,
    HouseDrink.water,
    HouseDrink.tea,
    HouseDrink.juice,
  ],
  pets: const [HousePet.parrot, HousePet.dog, HousePet.fish, HousePet.cat],
);

@immutable
final class FourHouseReference {
  const FourHouseReference({required this.solutions});

  final List<FourHouseGrid> solutions;

  bool get isUnique => solutions.length == 1;

  FourHouseGrid get uniqueGrid => solutions.single;
}

FourHouseReference evaluateFourHouseReference() {
  final solutions = <FourHouseGrid>[];
  for (final residents in _permutations(HouseResident.values)) {
    for (final drinks in _permutations(HouseDrink.values)) {
      for (final pets in _permutations(HousePet.values)) {
        final grid = FourHouseGrid(
          residents: residents,
          drinks: drinks,
          pets: pets,
        );
        if (grid.hasUniqueCategories && grid.satisfiesAllClues) {
          solutions.add(grid);
        }
      }
    }
  }
  return FourHouseReference(
    solutions: List<FourHouseGrid>.unmodifiable(solutions),
  );
}

final FourHouseReference fourHouseReference = evaluateFourHouseReference();

Iterable<List<T>> _permutations<T>(List<T> items) sync* {
  if (items.length <= 1) {
    yield List<T>.from(items);
    return;
  }
  for (var i = 0; i < items.length; i++) {
    final rest = <T>[...items.sublist(0, i), ...items.sublist(i + 1)];
    for (final perm in _permutations(rest)) {
      yield <T>[items[i], ...perm];
    }
  }
}
