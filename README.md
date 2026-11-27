# NiKAudio

NiKAudio truyền âm thanh hệ thống từ Windows sang iPhone qua Lightning hoặc Wi‑Fi. iPhone phát stereo bằng phiên âm thanh `.playback`, kể cả khi dùng TWS. Ứng dụng iOS không mở micro.

## Cài và kết nối

1. Mở GitHub Actions và tải hai artifact từ cùng một lần build. IPA cần được ký bằng công cụ sideload của bạn trước khi cài.
2. Mở NiKAudio trên iPhone và bấm **Bắt đầu nhận âm thanh**. Chạy `NiKAudioPC.exe` trên Windows. Cửa sổ Windows hiển thị trạng thái gửi âm thanh. Đóng cửa sổ để thu vào khay hệ thống, hoặc chọn **Thoát NiKAudio** để dừng ứng dụng.
3. Để dùng Lightning, cài Apple Devices hoặc Apple Mobile Device Support trên Windows và chấp nhận tin cậy máy tính trên iPhone.
4. Để dùng Wi‑Fi, mở **Ghép đôi Wi-Fi** trên iPhone. Chuyển khóa 64 ký tự sang PC qua kênh riêng, chép vào clipboard rồi chọn **Ghép đôi từ clipboard** trong cửa sổ, hoặc **Pair using key from clipboard** trong khay NiKAudio. Sau khi ghép đôi có thể xóa nội dung clipboard. Khóa được lưu trong Keychain và Windows Credential Manager.
5. Dùng chung LAN và cấp quyền mạng cục bộ trên iPhone. Nếu thiết bị không tự tìm thấy nhau, chạy `NiKAudioPC.exe <IP-iPhone>`. Chế độ IP thủ công vẫn cần ghép đôi.

Bản Windows và iOS có ghép đôi phải được cập nhật cùng nhau để dùng Wi‑Fi. Discovery xác thực bằng HMAC-SHA256 và âm thanh Wi‑Fi được bảo vệ bằng AES-256-GCM với khóa phiên ngắn hạn. TCP Lightning dùng giao diện loopback trên iPhone. Khi rút cáp, PC dùng đích LAN đã xác thực gần đây nếu có. Khi cắm lại, PC gửi chồng khoảng 250 ms và iPhone loại gói trùng theo số thứ tự.

## Tinh chỉnh và chẩn đoán

- **Độ trễ thấp** đặt mục tiêu 12 ms. Khi đang nhận, mục **Chất lượng phát** hiển thị mức đệm thực tế sau khi tính số frame mỗi lần iOS yêu cầu. **Ổn định** đặt 30 ms. Nếu LAN bị hụt khi có luồng âm thanh, ứng dụng tăng mức đệm theo bước 5 ms và giảm dần sau khi ổn định.
- Mở **Chẩn đoán** trên iPhone để xem mức đệm đang áp dụng, số lần hụt đệm, gói thiếu, gói muộn và thời gian giữa hai gói âm thanh được chấp nhận khi đổi đường truyền. Khoảng cách gói là chỉ số mạng. Độ ngắt nghe được còn phụ thuộc dữ liệu đang có trong bộ đệm.
- Khi PC đang im tiếng, heartbeat giữ trạng thái kết nối. **Pause streaming** trong khay Windows dừng gửi PCM và giữ heartbeat, và **Resume streaming** mở lại đầu vào WASAPI.

## Đo độ trễ trên thiết bị thật

1. Dùng một bộ thu hai kênh chung đồng hồ. Ghi đầu ra tham chiếu của PC vào kênh trái. Ghi đầu ra tai nghe iPhone có dây vào kênh phải, hoặc dùng một micro ngoài đặt sát một bên TWS. Nếu dùng thu âm riêng ở mỗi đầu, sai lệch đồng hồ sẽ làm kết quả khó so sánh.
2. Tắt nhạc và hiệu ứng âm thanh khác, bắt đầu ghi rồi chọn **Đo độ trễ** trong cửa sổ, hoặc **Play latency test pulses** trong khay. NiKAudio phát 20 xung qua thiết bị phát Windows mặc định, mỗi xung cách nhau hai giây.
3. Xuất file stereo PCM 16-bit WAV và chạy `python3 tools/measure_latency.py recording.wav`. Lưu số cặp khớp, median và p95. Đo lại qua USB và Wi‑Fi, lần lượt với đầu ra có dây và TWS. Chênh lệch giữa hai phép đo cùng đường truyền là ước tính phần độ trễ tăng thêm của đường phát TWS.
4. Chạy thêm một phiên nghe 30 phút khi khóa màn hình. Cắm/rút Lightning nhiều lần, ngắt/nối TWS, đổi thiết bị phát mặc định trên Windows và thử sleep/resume. Ghi số lần hụt và khoảng cách gói, rồi nghe lại bản ghi để đối chiếu với lúc mất tiếng thực tế.

## Phông chữ

Giao diện Windows và iPhone dùng chung Be Vietnam Pro, được nhúng trong ứng dụng theo giấy phép [SIL Open Font License](assets/fonts/OFL.txt).

## Khôi phục âm thanh và ghép đôi qua USB

- Chọn **Khôi phục âm thanh** nếu iPhone báo gián đoạn hoặc khôi phục tự động thất bại. Khi quay lại ứng dụng, NiKAudio thử mở lại engine nếu phiên nhận vẫn bật và engine đã dừng.
- Ghép đôi qua cáp bằng cách bật nhận âm thanh, cắm vào PC của bạn, mở **Ghép đôi Wi-Fi** và xác nhận **Gửi khóa qua cáp**. Trong 30 giây, chọn **Ghép đôi qua USB** trên PC và xác nhận lưu khóa. Cách dán clipboard vẫn có ở cửa sổ và khay.
- Heartbeat và gói đầu tiên sau khi WASAPI thu lại đánh dấu khoảng im ở PC. Nếu audio quay lại sau khi cạn bộ đệm mà chưa có một trong hai dấu này, NiKAudio tính một lần hụt và tăng mức đệm LAN. Tốc độ đọc bộ đệm thay đổi tối đa ±0,1% để bù lệch đồng hồ.
- Endpoint Windows 5.1/7.1 giữ gain kênh trước và giới hạn đỉnh khi có tín hiệu surround trộn vào ở khoảng −1 dBFS. Endpoint mono/stereo giữ đường chuyển đổi PCM hiện tại.

## Truyền tệp qua Wi-Fi

1. Ghép đôi NiKAudio trên hai thiết bị và cho phép ứng dụng Windows truy cập mạng riêng khi Windows Firewall hỏi. Điện thoại và PC cần cùng LAN. Cổng truyền tệp là TCP 55124.
2. Trên iPhone, vào **Tệp** và nhập IP được hiển thị ở mục **Truyền tệp LAN** trên PC.
3. Để gửi sang PC, bấm **Chọn tệp từ iPhone**. Windows lưu vào **Downloads/NiKAudio**. Để tải từ PC, kéo một tệp vào cửa sổ Windows hoặc bấm **Chọn tệp để gửi**, rồi bấm **Tải tệp đã chọn trên PC** trên điện thoại. Tệp đã nhận có thể xuất qua **Chia sẻ tệp đã nhận**.
4. Nếu bị gián đoạn, chọn lại đúng tệp hoặc bấm tải lại. Đầu nhận tiếp tục từ dữ liệu đã lưu và kiểm tra SHA-256 toàn tệp trước khi công bố bản hoàn chỉnh.

Tệp đi qua kết nối TCP riêng dùng AES-256-GCM với khóa phiên theo từng hướng, xác thực từ khóa ghép đôi. Một lượt truyền hoạt động tại một thời điểm. Không cần bật nhận âm thanh để chép tệp.
