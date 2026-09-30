// 볼륨이 마운트될 때 launchd가 실행: 앱을 깨워 DJI인지 판단하게 한다.
// 볼륨 파일에 접근하지 않으므로 권한 창이 뜨지 않는다.
#include <unistd.h>
int main(void) {
    execl("/usr/bin/open", "open", "-g", "dji2note://mounted", (char *)0);
    return 1;
}
