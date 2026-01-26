import { preferences } from '@kit.ArkData';
import { Context } from '@kit.AbilityKit';

/**
 * Preferences 工具类
 */
export class PreferencesUtil {
  private static readonly PREFERENCES_NAME = 'moonlight_settings';
  private static preferencesInstance: preferences.Preferences | null = null;

  static async getPreferences(context: Context): Promise<preferences.Preferences> {
    if (!PreferencesUtil.preferencesInstance) {
      PreferencesUtil.preferencesInstance = await preferences.getPreferences(
        context,
        PreferencesUtil.PREFERENCES_NAME
      );
    }
    return PreferencesUtil.preferencesInstance;
  }

  static async getString(context: Context, key: string, defaultValue: string = ''): Promise<string> {
    const prefs = await PreferencesUtil.getPreferences(context);
    return await prefs.get(key, defaultValue) as string;
  }

  static async setString(context: Context, key: string, value: string): Promise<void> {
    const prefs = await PreferencesUtil.getPreferences(context);
    await prefs.put(key, value);
    await prefs.flush();
  }

  static async getNumber(context: Context, key: string, defaultValue: number = 0): Promise<number> {
    const prefs = await PreferencesUtil.getPreferences(context);
    return await prefs.get(key, defaultValue) as number;
  }

  static async setNumber(context: Context, key: string, value: number): Promise<void> {
    const prefs = await PreferencesUtil.getPreferences(context);
    await prefs.put(key, value);
    await prefs.flush();
  }

  static async getBoolean(context: Context, key: string, defaultValue: boolean = false): Promise<boolean> {
    const prefs = await PreferencesUtil.getPreferences(context);
    return await prefs.get(key, defaultValue) as boolean;
  }

  static async setBoolean(context: Context, key: string, value: boolean): Promise<void> {
    const prefs = await PreferencesUtil.getPreferences(context);
    await prefs.put(key, value);
    await prefs.flush();
  }

  static async remove(context: Context, key: string): Promise<void> {
    const prefs = await PreferencesUtil.getPreferences(context);
    await prefs.delete(key);
    await prefs.flush();
  }

  static async clear(context: Context): Promise<void> {
    const prefs = await PreferencesUtil.getPreferences(context);
    await prefs.clear();
    await prefs.flush();
  }
}
