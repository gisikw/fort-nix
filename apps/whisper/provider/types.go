package main

// TranscribeRequest is the input format for the transcribe capability
type TranscribeRequest struct {
	Name   string       `json:"name"`   // Filename in /var/lib/fort/drops/
	Output OutputTarget `json:"output"` // Where to send the result
}

// OutputTarget specifies the destination for the transcription
type OutputTarget struct {
	Host string `json:"host"` // Target host name
	Name string `json:"name"` // Output filename
}

// TranscribeResponse is the output format for the transcribe capability
type TranscribeResponse struct {
	Status   string `json:"status,omitempty"`
	Filename string `json:"filename,omitempty"` // Name of output file on target
	Error    string `json:"error,omitempty"`
}
