import 'package:flutter/material.dart';

import '../../../models/campus_place.dart';
import '../../../utils/accessibility_scale.dart';

/// A single tappable tile in the category grid.
class CategoryButton extends StatelessWidget {
  final CategoryMeta cat;
  final void Function(CategoryMeta) onTap;

  const CategoryButton({
    super.key,
    required this.cat,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final textScaler = clampedTextScaler(context);

    return Semantics(
      button: true,
      label: cat.label,
      hint: 'Toca dos veces para explorar lugares',
      onTap: () => onTap(cat),
      child: ExcludeSemantics(
        child: Material(
          color: Colors.transparent,
          borderRadius: BorderRadius.circular(16),
          child: InkWell(
            onTap: () => onTap(cat),
            borderRadius: BorderRadius.circular(16),
            splashColor: const Color(0xFF1565C0).withValues(alpha: 0.28),
            highlightColor: const Color(0xFF1565C0).withValues(alpha: 0.14),
            child: Ink(
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.06),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(
                    color: Colors.white.withValues(alpha: 0.1)),
                boxShadow: const [
                  BoxShadow(
                      color: Color(0x22000000),
                      blurRadius: 6,
                      offset: Offset(0, 3)),
                ],
              ),
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  minHeight: responsiveSpace(context, 90),
                  minWidth: 48,
                ),
                child: Padding(
                  padding: EdgeInsets.symmetric(
                    horizontal: responsiveSpace(context, 6),
                    vertical: responsiveSpace(context, 8),
                  ),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Container(
                        width: responsiveSpace(context, 40),
                        height: responsiveSpace(context, 40),
                        decoration: BoxDecoration(
                          color: const Color(0xFF1565C0)
                              .withValues(alpha: 0.22),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Icon(
                          cat.iconData,
                          color: const Color(0xFF82B1FF),
                          size: 22,
                        ),
                      ),
                      const SizedBox(height: 7),
                      Text(
                        cat.label,
                        textScaler: textScaler,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                        ),
                        textAlign: TextAlign.center,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}