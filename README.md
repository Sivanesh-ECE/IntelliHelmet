# 🛡️ IntelliHelmet

### ESP32-Based Intelligent Smart Helmet for Real-Time Accident Detection & Emergency Alert System

<p align="center">
An Embedded Systems & IoT project focused on improving rider safety through intelligent accident detection, emergency alerting, and mobile connectivity.
</p>

---

## 📖 Overview

Road accidents are one of the leading causes of serious injuries and fatalities worldwide. A major challenge is the delay in notifying emergency contacts after an accident occurs.

**SmartShield** is an intelligent smart helmet designed to address this problem using Embedded Systems and IoT technologies. Built around the **ESP32 DevKit V1**, the system continuously monitors rider movement using the **MPU6050 accelerometer and gyroscope**. When abnormal impact and motion are detected, the helmet initiates a **5-second emergency countdown** to reduce false alarms. If the rider does not cancel the alert, the system automatically enters **Emergency Mode**, activates an audio alarm, displays the emergency status on the OLED screen, and sends an SOS notification via Bluetooth to the companion mobile application.

The project demonstrates practical applications of **Embedded Systems, Sensor Interfacing, Bluetooth Communication, Firmware Design, IoT Integration, and Mobile Application Development** to solve a real-world road safety problem.

---

# 🎯 Objectives

* Improve rider safety through intelligent accident detection.
* Reduce emergency response time.
* Minimize false accident alerts.
* Provide an affordable and scalable embedded safety solution.
* Demonstrate real-world Embedded Systems and IoT integration.

---

# 🚀 Key Features

* Real-Time Accident Detection
* Intelligent Motion Analysis
* 5-Second SOS Cancellation Countdown
* Manual SOS Button
* Emergency Alert System
* Bluetooth Communication
* OLED Status Display
* Audio Alarm using MAX98357A
* Finite State Machine Firmware
* Mobile Application Integration
* Modular and Scalable Architecture
* Future-ready for GPS, GSM, AI, and Cloud Integration

---

# 🛠 Hardware Components

| Component       | Purpose                   |
| --------------- | ------------------------- |
| ESP32 DevKit V1 | Main Controller           |
| MPU6050         | Accelerometer & Gyroscope |
| OLED SSD1306    | System Status Display     |
| MAX98357A       | I2S Audio Amplifier       |
| Speaker         | Emergency Alarm           |
| SOS Button      | Cancel/Manual Emergency   |
| Mode Button     | Alarm Control             |
| Bluetooth       | Mobile Communication      |

---

# 📌 Pin Configuration

| ESP32 GPIO | Connected Device     |
| ---------- | -------------------- |
| GPIO21     | SDA (OLED + MPU6050) |
| GPIO22     | SCL (OLED + MPU6050) |
| GPIO18     | SOS Button           |
| GPIO19     | Mode Button          |
| GPIO14     | MAX98357A DIN        |
| GPIO27     | MAX98357A BCLK       |
| GPIO32     | MAX98357A LRC        |

---

# ⚙️ System Workflow

```text
Power ON
      │
      ▼
OLED Initialization
      │
      ▼
MPU6050 Monitoring
      │
      ▼
Accident Detected?
      │
 ┌────┴────┐
 │         │
No        Yes
 │         │
 ▼         ▼
Continue  5-Second Countdown
           │
           ▼
SOS Cancelled?
     │
 ┌───┴────┐
 │        │
Yes      No
 │        │
 ▼        ▼
Monitoring Emergency Mode
            │
            ▼
Bluetooth SOS Alert
            │
            ▼
Speaker Alarm
            │
            ▼
Emergency Cleared
            │
            ▼
Back to Monitoring
```

---

# 🧠 Firmware Architecture

The firmware is implemented using a **Finite State Machine (FSM)** consisting of three primary states:

* Monitoring
* Countdown
* Emergency

This architecture provides deterministic behavior, modularity, and simplified debugging while improving reliability.

---

# 📱 Mobile Application

The companion application provides:

* Bluetooth Connectivity
* Helmet Status
* SOS Notifications
* Emergency Contact Management
* Ride History
* Future GPS Integration
* Future Cloud Synchronization
* Rider Profile Management

---

# 💻 Software Stack

### Embedded

* Arduino IDE
* ESP32 Framework
* Embedded C++

### Mobile

* Flutter
* Firebase (Future Integration)

### Communication

* Bluetooth Classic

---

# 📂 Project Structure

```text
SmartShield/
│
├── Firmware/
├── Mobile_App/
├── Circuit_Diagram/
├── Documentation/
├── Images/
├── README.md
└── LICENSE
```

---

# 🔬 Testing

The project has been validated for:

* OLED Initialization
* MPU6050 Sensor Reading
* Accident Detection Logic
* False Alert Prevention
* SOS Countdown
* Bluetooth Communication
* Speaker Alarm
* Emergency State Transition
* Manual SOS Activation
* Emergency Reset

---

# 🌍 Real-World Applications

* Motorcycle Rider Safety
* Delivery Riders
* Fleet Monitoring
* Smart Transportation
* Emergency Response Systems
* Student Research
* IoT Product Development
* Automotive Embedded Systems

---

# 🔮 Future Enhancements

* GPS Location Tracking
* GSM Emergency Calling
* AI-Based Accident Classification
* Voice Command Recognition
* Cloud Dashboard
* Firebase Integration
* Live Location Sharing
* Fall Detection Optimization
* Battery Monitoring
* OTA Firmware Updates

---

# 👨‍💻 Technologies Used

* Embedded Systems
* Internet of Things (IoT)
* ESP32
* Embedded C++
* Sensor Interfacing
* Bluetooth Communication
* Mobile App Development
* Firmware Engineering
* State Machine Design
* Real-Time Embedded Systems

---

# 📸 Project Preview

> Add the following screenshots to this section:

* Complete Hardware Setup
* OLED Monitoring Screen
* Accident Detection Screen
* Countdown Screen
* Emergency Mode Screen
* Mobile Application Dashboard
* Bluetooth Communication Demo

---

# 🤝 Contributing

Contributions, suggestions, and feature requests are welcome. Feel free to fork this repository, submit issues, or create pull requests to improve SmartShield.


# 👤 Author

**G. Sivanesh**

Electronics and Communication Engineering Student

Passionate about Embedded Systems, IoT, AI, and building intelligent technologies that solve real-world problems.

*"Engineering innovative solutions to make roads safer through Embedded Systems and IoT."*
DM FOR THE MOBILE APP FIRMWORK INFORMATION THROUGH GMAIL : sivaneshgnanasekar183@gmail.com
