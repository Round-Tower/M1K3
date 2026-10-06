// The plugin's `$.state` contract: every value the m1k3 mod keeps in the
// session, declared under its name. `claude plugin validate` holds the module
// to it.

export type Avatar = 'face' | 'fox' | 'phosphor' | 'off'

export type Mood = {
  emotion: 'neutral' | 'happy' | 'sad' | 'angry' | 'surprised' | 'love' | 'thinking' | 'excited' | 'sleepy'
  activity: 'idle' | 'listening' | 'thinking' | 'generating' | 'speaking' | 'error'
  /** When this mood was set, ms since the epoch; a settle timer checks it before overwriting. */
  since: number
}

declare module 'claude-code' {
  interface PluginState {
    m1k3: {
      avatar: Avatar
      mood: Mood
      isBandHidden: boolean
      note: string
    }
  }
}
