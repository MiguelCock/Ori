import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../models/campus_place.dart';
import '../../../services/geojson_service.dart';
import '../../../utils/accessibility_scale.dart';
import 'category_button.dart';

/// Responsive wrap grid of [CategoryButton] tiles.
/// Column count adapts to available width: 2 (narrow) → 3 → 4 (wide).
class CategoryGrid extends StatelessWidget {
  final void Function(CategoryMeta) onCategoryTap;

  const CategoryGrid({super.key, required this.onCategoryTap});

  @override
  Widget build(BuildContext context) {
    return Consumer<GeoJsonService>(
      builder: (_, geo, _) {
        final categories = geo.categories;
        return LayoutBuilder(
          builder: (context, constraints) {
            final width = constraints.maxWidth;
            final columns = width < 330
                ? 2
                : width > 520
                    ? 4
                    : 3;
            final spacing = responsiveSpace(context, 12);
            final itemWidth =
                (width - spacing * (columns - 1)) / columns;

            return Wrap(
              spacing: spacing,
              runSpacing: spacing,
              children: [
                for (final category in categories)
                  SizedBox(
                    width: itemWidth,
                    child: CategoryButton(category: category, onTap: onCategoryTap),
                  ),
              ],
            );
          },
        );
      },
    );
  }
}