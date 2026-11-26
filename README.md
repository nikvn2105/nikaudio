# NiKAudio

NiKAudio truyền âm thanh hệ thống từ Windows sang iPhone qua Lightning hoặc Wi‑Fi. iPhone phát stereo bằng phiên âm thanh `.playback`, kể cả khi dùng TWS. Ứng dụng iOS không mở micro.

## Cài và kết nối

1. Mở GitHub Actions và tải hai artifact từ cùng một lần build. IPA cần được ký bằng công cụ sideload của bạn trước khi cài.
2. Mở NiKAudio trên iPhone và bấm **Bắt đầu nhận âm thanh**. Chạy `NiKAudioPC.exe` trên Windows. Biểu tượng NiKAudio nằm trong khay hệ thống.
3. Để dùng Lightning, cài Apple Devices hoặc Apple Mobile Device Support trên Windows và chấp nhận tin cậy máy tính trên iPhone.
4. Để dùng Wi‑Fi, mở **Ghép đôi Wi-Fi** trên iPhone. Chuyển khóa 64 ký tự sang PC qua kênh riêng, chép vào clipboard rồi chọn **Pair using key from clipboard** trong khay NiKAudio. Sau khi ghép đôi có thể xóa nội dung clipboard. Khóa được lưu trong Keychain và Windows Credential Manager.
5. Dùng chung LAN và cấp quyền mạng cục bộ trên iPhone. Nếu thiết bị không tự tìm thấy nhau, chạy `NiKAudioPC.exe <IP-iPhone>`. Chế độ IP thủ công vẫn cần ghép đôi.

Bản Windows và iOS có ghép đôi phải được cập nhật cùng nhau để dùng Wi‑Fi. Discovery xác thực bằng HMAC-SHA256 và âm thanh Wi‑Fi được bảo vệ bằng AES-256-GCM với khóa phiên ngắn hạn. TCP Lightning dùng giao diện loopback trên iPhone. Khi rút cáp, PC dùng đích LAN đã xác thực gần đây nếu có. Khi cắm lại, PC gửi chồng khoảng 250 ms và iPhone loại gói trùng theo số thứ tự.

## Tinh chỉnh và chẩn đoán

- **Độ trễ thấp** đặt mức đệm 12 ms. **Ổn định** đặt 30 ms. Nếu LAN bị hụt khi có luồng âm thanh, ứng dụng tăng mức đệm theo bước 5 ms và giảm dần sau khi ổn định.
- Mở **Chẩn đoán** trên iPhone để xem mức đệm đang áp dụng, số lần hụt đệm, gói thiếu, gói muộn và thời gian giữa hai gói âm thanh được chấp nhận khi đổi đường truyền. Khoảng cách gói là chỉ số mạng. Độ ngắt nghe được còn phụ thuộc dữ liệu đang có trong bộ đệm.
- Khi PC đang im tiếng, heartbeat giữ trạng thái kết nối. **Pause streaming** trong khay Windows dừng gửi, và **Resume streaming** mở lại đầu vào WASAPI.

## Đo độ trễ trên thiết bị thật

1. Dùng một bộ thu hai kênh chung đồng hồ. Ghi đầu ra tham chiếu của PC vào kênh trái. Ghi đầu ra tai nghe iPhone có dây vào kênh phải, hoặc dùng một micro ngoài đặt sát một bên TWS. Nếu dùng thu âm riêng ở mỗi đầu, sai lệch đồng hồ sẽ làm kết quả khó so sánh.
2. Tắt nhạc và hiệu ứng âm thanh khác, bắt đầu ghi rồi chọn **Play latency test pulses** trong khay. NiKAudio phát 20 xung qua thiết bị phát Windows mặc định, mỗi xung cách nhau hai giây.
3. Xuất file stereo PCM 16-bit WAV và chạy `python3 tools/measure_latency.py recording.wav`. Lưu số cặp khớp, median và p95. Đo lại qua USB và Wi‑Fi, lần lượt với đầu ra có dây và TWS. Chênh lệch giữa hai phép đo cùng đường truyền là ước tính phần độ trễ tăng thêm của đường phát TWS.
4. Chạy thêm một phiên nghe 30 phút khi khóa màn hình. Cắm/rút Lightning nhiều lần, ngắt/nối TWS, đổi thiết bị phát mặc định trên Windows và thử sleep/resume. Ghi số lần hụt và khoảng cách gói, rồi nghe lại bản ghi để đối chiếu với lúc mất tiếng thực tế.
