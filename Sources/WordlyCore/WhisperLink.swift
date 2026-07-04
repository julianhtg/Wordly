import whisper

public enum WhisperLink {
    public static var isLinked: Bool { whisper_lang_max_id() > 0 }
}
