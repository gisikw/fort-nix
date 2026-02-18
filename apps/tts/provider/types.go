package main

// TTSRequest is the input format for the tts capability
type TTSRequest struct {
	Text   string       `json:"text"`            // Text to synthesize
	Voice  string       `json:"voice,omitempty"` // Voice name (default: af_heart)
	Format string       `json:"format,omitempty"` // Output format: mp3, wav, opus (default: mp3)
	Output OutputTarget `json:"output"`          // Where to send the result
}

// OutputTarget specifies the destination for the audio file
type OutputTarget struct {
	Host string `json:"host"` // Target host name
	Name string `json:"name"` // Output filename
}

// TTSResponse is the output format for the tts capability
type TTSResponse struct {
	Status string `json:"status,omitempty"`
	Error  string `json:"error,omitempty"`
}
