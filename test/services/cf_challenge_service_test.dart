import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/services/cf_challenge_service.dart';

void main() {
  test('Aqua handoff state machine only permits the safe lifecycle order', () {
    final machine = CfAquaHandoffStateMachine();

    expect(machine.transition(CfAquaHandoffPhase.backgroundVerifying), isTrue);
    expect(machine.transition(CfAquaHandoffPhase.foregroundVerifying), isFalse);
    expect(machine.transition(CfAquaHandoffPhase.handoffDraining), isTrue);
    expect(machine.transition(CfAquaHandoffPhase.foregroundCreating), isTrue);
    expect(machine.transition(CfAquaHandoffPhase.foregroundVerifying), isTrue);
    expect(machine.transition(CfAquaHandoffPhase.settling), isTrue);
    expect(machine.transition(CfAquaHandoffPhase.idle), isTrue);
    expect(machine.phase, CfAquaHandoffPhase.idle);
    expect(machine.generation, 6);
  });

  test('Aqua handoff state machine rejects re-entry from an active phase', () {
    final machine = CfAquaHandoffStateMachine();

    expect(machine.transition(CfAquaHandoffPhase.backgroundVerifying), isTrue);
    expect(machine.transition(CfAquaHandoffPhase.backgroundVerifying), isFalse);
    expect(machine.generation, 1);
  });
}
