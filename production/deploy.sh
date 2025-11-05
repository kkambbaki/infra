#!/bin/bash

# 프로덕션 배포 스크립트
# EC2 서버에서 실행됩니다.
# GitHub Actions 또는 수동으로 실행 가능합니다.

set -e

# 스크립트 실행 위치 기록
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# 색상 정의
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# 로깅 함수
log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# 배포 디렉토리로 이동
# 스크립트가 있는 디렉토리를 기본값으로 사용
DEPLOY_DIR="${DEPLOY_DIR:-$SCRIPT_DIR}"
cd "$DEPLOY_DIR" || {
    log_error "배포 디렉토리를 찾을 수 없습니다: $DEPLOY_DIR"
    exit 1
}

log_info "배포 디렉토리: $DEPLOY_DIR"

# .env 파일 확인
if [ ! -f .env ]; then
    log_error ".env 파일이 존재하지 않습니다. .env.example을 참고하여 생성하세요."
    exit 1
fi

# Docker 이미지 태그 설정
DOCKER_IMAGE_TAG="${DOCKER_IMAGE_TAG:-production}"
log_info "Docker 이미지 태그: $DOCKER_IMAGE_TAG"

# .env 파일에서 DOCKER_USERNAME, DOCKER_IMAGE_NAME 읽기
source .env

if [ -z "$DOCKER_USERNAME" ] || [ -z "$DOCKER_IMAGE_NAME" ]; then
    log_error "DOCKER_USERNAME 또는 DOCKER_IMAGE_NAME이 설정되지 않았습니다."
    exit 1
fi

WEBAPP_IMAGE="$DOCKER_USERNAME/$DOCKER_IMAGE_NAME:$DOCKER_IMAGE_TAG"
CELERY_IMAGE="$DOCKER_USERNAME/$DOCKER_IMAGE_NAME:$DOCKER_IMAGE_TAG-celery"

log_info "Webapp 이미지: $WEBAPP_IMAGE"
log_info "Celery 이미지: $CELERY_IMAGE"

# Docker 이미지 Pull
log_info "Docker 이미지를 Pull 합니다..."
docker pull "$WEBAPP_IMAGE" || {
    log_error "Webapp 이미지 Pull 실패"
    exit 1
}

docker pull "$CELERY_IMAGE" || {
    log_error "Celery 이미지 Pull 실패"
    exit 1
}

log_info "Docker 이미지 Pull 완료"

# 백업 (선택사항)
# log_info "데이터베이스 백업 중..."
# BACKUP_DIR="$HOME/backups"
# mkdir -p "$BACKUP_DIR"
# BACKUP_FILE="$BACKUP_DIR/db_backup_$(date +%Y%m%d_%H%M%S).sql"
# pg_dump -U ${POSTGRES_USER} -h localhost ${POSTGRES_DB} > "$BACKUP_FILE"
# log_info "백업 완료: $BACKUP_FILE"

# Docker Compose 서비스 재시작
log_info "Docker Compose 서비스를 재시작합니다..."

# Graceful shutdown
docker-compose down --timeout 30

# 새 컨테이너 시작
docker-compose up -d

# 컨테이너 시작 대기 및 확인
log_info "컨테이너 시작을 기다립니다..."
MAX_WAIT=60
WAIT_COUNT=0

while [ $WAIT_COUNT -lt $MAX_WAIT ]; do
    # webapp 컨테이너가 실행 중인지 확인
    if docker-compose ps webapp | grep -q "Up"; then
        log_info "webapp 컨테이너가 시작되었습니다."

        # 컨테이너가 실제로 요청을 받을 준비가 되었는지 추가 확인
        sleep 3

        # Django가 준비되었는지 확인
        if docker-compose exec -T webapp python -c "import django; print('Django OK')" 2>/dev/null | grep -q "Django OK"; then
            log_info "Django 애플리케이션이 준비되었습니다."
            break
        else
            log_info "Django 애플리케이션이 아직 준비 중입니다..."
        fi
    else
        log_info "webapp 컨테이너 시작 대기 중... (${WAIT_COUNT}초/${MAX_WAIT}초)"
    fi

    WAIT_COUNT=$((WAIT_COUNT + 1))
    sleep 1
done

if [ $WAIT_COUNT -eq $MAX_WAIT ]; then
    log_error "컨테이너 시작 시간 초과"
    docker-compose ps
    docker-compose logs --tail=50 webapp
    exit 1
fi

log_info "컨테이너 시작 완료"

# 마이그레이션 실행
log_info "데이터베이스 마이그레이션을 실행합니다..."
docker-compose exec -T webapp python manage.py migrate --noinput || {
    log_error "마이그레이션 실패"
    exit 1
}

log_info "마이그레이션 완료"

# Static 파일 수집
log_info "Static 파일을 수집합니다..."
docker-compose exec -T webapp python manage.py collectstatic --noinput || {
    log_warning "Static 파일 수집 실패 (무시하고 진행)"
}

# 헬스 체크
log_info "헬스 체크를 실행합니다..."
sleep 5

HEALTH_CHECK_URL="${HEALTH_CHECK_URL:-http://localhost/health/}"
MAX_RETRIES=10
RETRY_COUNT=0

while [ $RETRY_COUNT -lt $MAX_RETRIES ]; do
    HTTP_STATUS=$(curl -s -o /dev/null -w "%{http_code}" "$HEALTH_CHECK_URL" || echo "000")

    if [ "$HTTP_STATUS" = "200" ] || [ "$HTTP_STATUS" = "301" ] || [ "$HTTP_STATUS" = "302" ]; then
        log_info "헬스 체크 성공 (HTTP $HTTP_STATUS)"
        break
    else
        RETRY_COUNT=$((RETRY_COUNT + 1))
        log_warning "헬스 체크 실패 (HTTP $HTTP_STATUS), 재시도 중... ($RETRY_COUNT/$MAX_RETRIES)"
        sleep 3
    fi
done

if [ $RETRY_COUNT -eq $MAX_RETRIES ]; then
    log_error "헬스 체크 실패. 서비스가 정상적으로 시작되지 않았습니다."
    log_info "로그 확인:"
    docker-compose logs --tail=50 webapp
    exit 1
fi

# 서비스 상태 확인
log_info "서비스 상태:"
docker-compose ps

# 디스크 사용량 확인
log_info "디스크 사용량:"
df -h | grep -E '(Filesystem|/$)'

# 메모리 사용량 확인
log_info "메모리 사용량:"
free -h

# 배포 완료
log_info "배포가 완료되었습니다!"
log_info "웹사이트: http://$(curl -s ifconfig.me)"
log_info "Flower: http://$(curl -s ifconfig.me):5555"

# 로그 출력 (선택사항)
# log_info "최근 로그:"
# docker-compose logs --tail=20
