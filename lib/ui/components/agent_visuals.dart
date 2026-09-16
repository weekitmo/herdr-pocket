import 'package:flutter/cupertino.dart';
import 'package:herdr_pocket/domain/agent/agent_group.dart';
import 'package:herdr_pocket/l10n/generated/app_localizations.dart';
import 'package:herdr_pocket/ui/design/tokens.dart';

/// Localized section heading for a group.
///
/// Returns the English label uppercased and the Chinese label as-is. That
/// asymmetry is deliberate, not an oversight: `toUpperCase()` is a NO-OP on Han
/// characters, so the "uppercase micro-label" convention herdrup uses simply
/// does not exist in Chinese. Rendering a zh section heading with the tracking
/// and weight of an all-caps English one would produce a cramped, wrong-looking
/// line. Chinese headings lean on weight and spacing instead.
({String text, TextStyle Function(HerdrColors) style}) groupHeading(
  AppLocalizations l10n,
  AgentGroup group,
) {
  final raw = switch (group) {
    AgentGroup.needsYou => l10n.groupNeedsYou,
    AgentGroup.stopped => l10n.groupStopped,
    AgentGroup.unrecognised => l10n.groupUnrecognised,
    AgentGroup.working => l10n.groupWorking,
    AgentGroup.idle => l10n.groupIdle,
  };

  final isCjk = RegExp(r'[\u4e00-\u9fff]').hasMatch(raw);

  return (
    text: isCjk ? raw : raw.toUpperCase(),
    style: (HerdrColors c) => TextStyle(
          color: c.textFaint,
          fontSize: isCjk ? TextSize.meta : TextSize.micro,
          fontWeight: FontWeight.w600,
          // Letter-spacing is what makes an all-caps label read as a label; in
          // Chinese it just adds air between characters that are already
          // square, so it is halved rather than removed.
          letterSpacing: isCjk ? 0.5 : 0.8,
          height: 1.2,
        ),
  );
}

/// The status colour for a group.
///
/// Colour is MEANING here, not decoration — this is the only place in the app
/// that carries colour, and it is the reason the palette is otherwise
/// achromatic. Note `.unrecognised` renders amber on purpose: "this build
/// cannot read it" is nearer to needs-attention than to nothing-to-do, which is
/// the same reasoning that sorts it above working.
Color groupColor(HerdrColors c, AgentGroup group) => switch (group) {
      AgentGroup.needsYou => c.waiting,
      AgentGroup.stopped => c.died,
      AgentGroup.unrecognised => c.waiting,
      AgentGroup.working => c.working,
      AgentGroup.idle => c.textFaint,
    };

/// A filled dot that softly pulses only while the agent is working.
///
/// Colour carries the meaning; the motion says "alive" without claiming a
/// duration. Everything non-working holds perfectly still — a board where
/// several things move at once is a board you cannot read.
class AgentStatusDot extends StatefulWidget {
  const AgentStatusDot({
    required this.color,
    required this.isActive,
    this.diameter = 8,
    super.key,
  });

  final Color color;
  final bool isActive;
  final double diameter;

  @override
  State<AgentStatusDot> createState() => _AgentStatusDotState();
}

class _AgentStatusDotState extends State<AgentStatusDot>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: Motion.pulse,
  );

  @override
  void initState() {
    super.initState();
    if (widget.isActive) _controller.repeat(reverse: true);
  }

  @override
  void didUpdateWidget(AgentStatusDot oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.isActive == oldWidget.isActive) return;
    if (widget.isActive) {
      _controller.repeat(reverse: true);
    } else {
      // Snap back to solid immediately; a dot easing to a stop reads as the
      // agent finishing when it has not.
      _controller.stop();
      _controller.value = 0;
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) {
        final t = Curves.easeInOut.transform(_controller.value);
        return Opacity(
          opacity: widget.isActive ? 1 - 0.6 * t : 1,
          child: Transform.scale(
            scale: widget.isActive ? 1 + 0.35 * t : 1,
            child: Container(
              width: widget.diameter,
              height: widget.diameter,
              decoration: BoxDecoration(
                color: widget.color,
                shape: BoxShape.circle,
              ),
            ),
          ),
        );
      },
    );
  }
}

/// A thin broken ring that turns — the "working" state, at a size that suits a
/// row rather than a whole screen.
class WorkingRing extends StatefulWidget {
  const WorkingRing({
    required this.color,
    this.diameter = 14,
    this.strokeWidth = 1.6,
    super.key,
  });

  final Color color;
  final double diameter;
  final double strokeWidth;

  @override
  State<WorkingRing> createState() => _WorkingRingState();
}

class _WorkingRingState extends State<WorkingRing>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: Motion.spinner,
  )..repeat();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return RotationTransition(
      turns: _controller,
      child: CustomPaint(
        size: Size.square(widget.diameter),
        painter: _RingPainter(
          color: widget.color,
          strokeWidth: widget.strokeWidth,
        ),
      ),
    );
  }
}

class _RingPainter extends CustomPainter {
  _RingPainter({required this.color, required this.strokeWidth});

  final Color color;
  final double strokeWidth;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth
      ..strokeCap = StrokeCap.round;

    // 0.72 of a circle: an unbroken ring reads as a spinner and a full ring
    // reads as a badge. The gap is what makes it legible as motion.
    canvas.drawArc(
      Rect.fromLTWH(
        strokeWidth / 2,
        strokeWidth / 2,
        size.width - strokeWidth,
        size.height - strokeWidth,
      ),
      -1.5708, // start at 12 o'clock
      4.52, // ~0.72 of a turn
      false,
      paint,
    );
  }

  @override
  bool shouldRepaint(_RingPainter old) =>
      old.color != color || old.strokeWidth != strokeWidth;
}

/// The identity colour carried by an agent kind.
///
/// The ONLY decorative colour in the app, and it earns its place: it tells you
/// at a glance whether a card is a claude or a codex without reading the title.
///
/// Solid, not a gradient. A gradient on an 18pt chip is not a gradient anyone
/// can see — it is just a muddy colour — and it made every card look slightly
/// different from every other card for no informational gain. Hues are kept
/// clear of the working blue so identity never collides with status.
Color agentIdentityColor(String agent) {
  final a = agent.toLowerCase();
  if (a.contains('claude')) return const Color(0xFFCE58A4); // magenta
  if (a.contains('codex')) return const Color(0xFFE8923C); // orange
  if (a.contains('gemini')) return const Color(0xFF4C6EF5); // indigo
  if (a.contains('pi')) return const Color(0xFF3FB6A8); // teal
  return const Color(0xFF8B79F6); // violet
}

/// One glyph per agent kind.
///
/// Distinct marks rather than first letters, because claude and codex would
/// both render "C" and the chip would stop identifying anything.
String agentGlyph(String agent) {
  final a = agent.toLowerCase();
  if (a.contains('claude')) return '\u2731'; // heavy asterisk, no emoji form
  if (a.contains('codex')) return 'C';
  if (a.contains('gemini')) return '\u2726'; // four-pointed star
  if (a.contains('pi')) return '\u03C0'; // greek small letter pi
  final first = agent.trim();
  return first.isEmpty ? '?' : first.characters.first.toUpperCase();
}
