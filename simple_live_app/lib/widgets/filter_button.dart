import 'package:material_ui/material_ui.dart';
import 'package:simple_live_app/app/app_style.dart';

class FilterButton extends StatelessWidget {
  final bool selected;
  final String text;
  final Function()? onTap;

  /// 可选：chip 左侧的小图标/logo
  final Widget? leading;
  const FilterButton({
    this.selected = false,
    required this.text,
    this.onTap,
    this.leading,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: AppStyle.radius24,
      onTap: onTap,
      child: Container(
        padding: AppStyle.edgeInsetsH12.copyWith(top: 4, bottom: 4),
        decoration: BoxDecoration(
          border: Border.all(color: selected ? Theme.of(context).textTheme.bodyMedium!.color! : Colors.grey),
          borderRadius: AppStyle.radius24,
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (leading != null) ...[leading!, AppStyle.hGap4],
            Text(
              text,
              style: selected
                  ? Theme.of(context).textTheme.bodyMedium
                  : Theme.of(context).textTheme.bodyMedium!.copyWith(
                        color: Colors.grey,
                      ),
            ),
          ],
        ),
      ),
    );
  }
}
