import { InputMethodExtensionAbility } from '@kit.IMEKit';
import { Want } from '@kit.AbilityKit';
import { mixedController } from './model/MixedController';

const TAG: string = 'HMixedService';

export default class HMixedService extends InputMethodExtensionAbility {
  onCreate(want: Want): void {
    console.info(`${TAG} onCreate, ability: ${want.abilityName ?? ''}`);
    mixedController.onCreate(this.context);
  }

  onDestroy(): void {
    console.info(`${TAG} onDestroy`);
    mixedController.onDestroy();
  }
}
