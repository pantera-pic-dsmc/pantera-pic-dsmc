MODULE postprocess

   USE global
   USE screen
   USE grid_and_partition
   USE fields

   IMPLICIT NONE

   CONTAINS

   !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
   ! SUBROUTINE GRID_AVG -> Adds timestep to cumulative average !!!!!!!!!
   !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!

   SUBROUTINE GRID_AVG

      IMPLICIT NONE

      INTEGER                            :: NCELLS, NSPECIES
      INTEGER                            :: JP, JC, JS, INDEX

      REAL(KIND=8) :: DBLE_AVG_CUMULATED, NUMPART, SAMPLEDOF
      REAL(KIND=8) :: CX, CY, CZ, C2, MASS, VOL, CFNUM 

   
      INTEGER, DIMENSION(:), ALLOCATABLE      :: TIMESTEP_NP

      INTEGER, DIMENSION(:), ALLOCATABLE      :: TIMESTEP_N
   
      REAL(KIND=8), DIMENSION(:), ALLOCATABLE :: TIMESTEP_VX
      REAL(KIND=8), DIMENSION(:), ALLOCATABLE :: TIMESTEP_VY
      REAL(KIND=8), DIMENSION(:), ALLOCATABLE :: TIMESTEP_VZ

      REAL(KIND=8), DIMENSION(:), ALLOCATABLE :: TIMESTEP_VX2
      REAL(KIND=8), DIMENSION(:), ALLOCATABLE :: TIMESTEP_VY2
      REAL(KIND=8), DIMENSION(:), ALLOCATABLE :: TIMESTEP_VZ2
   
      REAL(KIND=8), DIMENSION(:), ALLOCATABLE :: TIMESTEP_TTRX
      REAL(KIND=8), DIMENSION(:), ALLOCATABLE :: TIMESTEP_TTRY
      REAL(KIND=8), DIMENSION(:), ALLOCATABLE :: TIMESTEP_TTRZ
      REAL(KIND=8), DIMENSION(:), ALLOCATABLE :: TIMESTEP_TTR

      REAL(KIND=8), DIMENSION(:), ALLOCATABLE :: TIMESTEP_EROT
      REAL(KIND=8), DIMENSION(:), ALLOCATABLE :: TIMESTEP_EVIB
      REAL(KIND=8), DIMENSION(:), ALLOCATABLE :: TIMESTEP_TROT
      REAL(KIND=8), DIMENSION(:), ALLOCATABLE :: TIMESTEP_TVIB

      LOGICAL, DIMENSION(:), ALLOCATABLE      :: INTENSIVE_AVERAGE_ONE
      LOGICAL, DIMENSION(:), ALLOCATABLE      :: INTENSIVE_AVERAGE_TWO

      REAL(KIND=8), DIMENSION(:,:), ALLOCATABLE :: TIMESTEP_MOMENTS

      REAL(KIND=8), DIMENSION(:,:), ALLOCATABLE :: TIMESTEP_PHI

      INTEGER :: LENGTH


      LENGTH = NX*NY * N_SPECIES

      ALLOCATE(TIMESTEP_NP(LENGTH))
      
      ALLOCATE(TIMESTEP_N(LENGTH))

      ALLOCATE(TIMESTEP_VX(LENGTH))
      ALLOCATE(TIMESTEP_VY(LENGTH))
      ALLOCATE(TIMESTEP_VZ(LENGTH))

      ALLOCATE(TIMESTEP_VX2(LENGTH))
      ALLOCATE(TIMESTEP_VY2(LENGTH))
      ALLOCATE(TIMESTEP_VZ2(LENGTH))
      
      ALLOCATE(TIMESTEP_TTRX(LENGTH))
      ALLOCATE(TIMESTEP_TTRY(LENGTH))
      ALLOCATE(TIMESTEP_TTRZ(LENGTH))
      ALLOCATE(TIMESTEP_TTR(LENGTH))
      
      ALLOCATE(TIMESTEP_EROT(LENGTH))
      ALLOCATE(TIMESTEP_EVIB(LENGTH))

      ALLOCATE(TIMESTEP_TROT(LENGTH))
      ALLOCATE(TIMESTEP_TVIB(LENGTH))

      ALLOCATE(INTENSIVE_AVERAGE_ONE(LENGTH))
      ALLOCATE(INTENSIVE_AVERAGE_TWO(LENGTH))

      TIMESTEP_NP = 0

      TIMESTEP_N = 0

      TIMESTEP_VX = 0
      TIMESTEP_VY = 0
      TIMESTEP_VZ = 0

      TIMESTEP_VX2 = 0
      TIMESTEP_VY2 = 0
      TIMESTEP_VZ2 = 0

      TIMESTEP_TTRX = 0
      TIMESTEP_TTRY = 0
      TIMESTEP_TTRZ = 0
      TIMESTEP_TTR = 0

      TIMESTEP_EROT = 0
      TIMESTEP_EVIB = 0

      TIMESTEP_TROT = 0
      TIMESTEP_TVIB = 0

      INTENSIVE_AVERAGE_ONE = .FALSE.
      INTENSIVE_AVERAGE_TWO = .FALSE.

      IF (BOOL_DUMP_MOMENTS) THEN
         ALLOCATE(TIMESTEP_MOMENTS(LENGTH,33))
         TIMESTEP_MOMENTS = 0
      END IF


      NCELLS = NX*NY
      NSPECIES = N_SPECIES

      ! Compute average values for this timestep on this process

      ! Number of particles
      DO JP = 1, NP_PROC
         JC = particles(JP)%IC
         JS = particles(JP)%S_ID
         INDEX = JC+NCELLS*(JS-1)
         TIMESTEP_NP(INDEX) = TIMESTEP_NP(INDEX) + 1
      END DO

      ! Velocity
      DO JP = 1, NP_PROC
         JC = particles(JP)%IC
         JS = particles(JP)%S_ID
         INDEX = JC+NCELLS*(JS-1)
         TIMESTEP_VX(INDEX) = TIMESTEP_VX(INDEX) + particles(JP)%VX
         TIMESTEP_VY(INDEX) = TIMESTEP_VY(INDEX) + particles(JP)%VY
         TIMESTEP_VZ(INDEX) = TIMESTEP_VZ(INDEX) + particles(JP)%VZ
      END DO


      DO INDEX = 1, NCELLS*NSPECIES
         IF (TIMESTEP_NP(INDEX) .GT. 0) THEN
            INTENSIVE_AVERAGE_ONE(INDEX) = .TRUE.
            TIMESTEP_VX(INDEX) = TIMESTEP_VX(INDEX) / DBLE(TIMESTEP_NP(INDEX))
            TIMESTEP_VY(INDEX) = TIMESTEP_VY(INDEX) / DBLE(TIMESTEP_NP(INDEX))
            TIMESTEP_VZ(INDEX) = TIMESTEP_VZ(INDEX) / DBLE(TIMESTEP_NP(INDEX))
         END IF
      END DO

      ! Translational Temperature and internal energy
      DO JP = 1, NP_PROC
         JC = particles(JP)%IC
         JS = particles(JP)%S_ID
         INDEX = JC+NCELLS*(JS-1)
         TIMESTEP_VX2(INDEX) = TIMESTEP_VX2(INDEX) + particles(JP)%VX*particles(JP)%VX
         TIMESTEP_VY2(INDEX) = TIMESTEP_VY2(INDEX) + particles(JP)%VY*particles(JP)%VY
         TIMESTEP_VZ2(INDEX) = TIMESTEP_VZ2(INDEX) + particles(JP)%VZ*particles(JP)%VZ

         TIMESTEP_EROT(INDEX) = TIMESTEP_EROT(INDEX) + particles(JP)%EROT
         TIMESTEP_EVIB(INDEX) = TIMESTEP_EVIB(INDEX) + particles(JP)%EVIB
      END DO


      IF (BOOL_DUMP_MOMENTS) THEN
         ! Higher order moments
         DO JP = 1, NP_PROC
            JC = particles(JP)%IC
            JS = particles(JP)%S_ID
            INDEX = JC+NCELLS*(JS-1)

            CX = particles(JP)%VX - TIMESTEP_VX(INDEX)
            CY = particles(JP)%VY - TIMESTEP_VY(INDEX)
            CZ = particles(JP)%VZ - TIMESTEP_VZ(INDEX)

            C2 = CX*CX + CY*CY + CZ*CZ
            TIMESTEP_MOMENTS(INDEX,5)  = TIMESTEP_MOMENTS(INDEX,5)  + CX*CX ! Pxx
            TIMESTEP_MOMENTS(INDEX,6)  = TIMESTEP_MOMENTS(INDEX,6)  + CX*CY ! Pxy
            TIMESTEP_MOMENTS(INDEX,7)  = TIMESTEP_MOMENTS(INDEX,7)  + CX*CZ ! Pxz
            TIMESTEP_MOMENTS(INDEX,8)  = TIMESTEP_MOMENTS(INDEX,8)  + CY*CY ! Pyy
            TIMESTEP_MOMENTS(INDEX,9)  = TIMESTEP_MOMENTS(INDEX,9)  + CY*CZ ! Pyz
            TIMESTEP_MOMENTS(INDEX,10) = TIMESTEP_MOMENTS(INDEX,10) + CZ*CZ ! Pzz

            TIMESTEP_MOMENTS(INDEX,11) = TIMESTEP_MOMENTS(INDEX,11) + CX*C2 ! qx
            TIMESTEP_MOMENTS(INDEX,12) = TIMESTEP_MOMENTS(INDEX,12) + CY*C2 ! qy
            TIMESTEP_MOMENTS(INDEX,13) = TIMESTEP_MOMENTS(INDEX,13) + CZ*C2 ! qz

            TIMESTEP_MOMENTS(INDEX,14) = TIMESTEP_MOMENTS(INDEX,14) + CX*CX*CX ! Qxxx
            TIMESTEP_MOMENTS(INDEX,15) = TIMESTEP_MOMENTS(INDEX,15) + CX*CX*CY ! Qxxy
            TIMESTEP_MOMENTS(INDEX,16) = TIMESTEP_MOMENTS(INDEX,16) + CX*CY*CY ! Qxyy
            TIMESTEP_MOMENTS(INDEX,17) = TIMESTEP_MOMENTS(INDEX,17) + CY*CY*CY ! Qyyy
            TIMESTEP_MOMENTS(INDEX,18) = TIMESTEP_MOMENTS(INDEX,18) + CY*CY*CZ ! Qyyz
            TIMESTEP_MOMENTS(INDEX,19) = TIMESTEP_MOMENTS(INDEX,19) + CY*CZ*CZ ! Qyzz
            TIMESTEP_MOMENTS(INDEX,20) = TIMESTEP_MOMENTS(INDEX,20) + CZ*CZ*CZ ! Qzzz
            TIMESTEP_MOMENTS(INDEX,21) = TIMESTEP_MOMENTS(INDEX,21) + CX*CX*CZ ! Qxxz
            TIMESTEP_MOMENTS(INDEX,22) = TIMESTEP_MOMENTS(INDEX,22) + CX*CZ*CZ ! Qxzz
            TIMESTEP_MOMENTS(INDEX,23) = TIMESTEP_MOMENTS(INDEX,23) + CX*CY*CZ ! Qxyz

            TIMESTEP_MOMENTS(INDEX,24) = TIMESTEP_MOMENTS(INDEX,24) + C2*C2 ! Riijj

            TIMESTEP_MOMENTS(INDEX,25) = TIMESTEP_MOMENTS(INDEX,25) + CX*CX*C2 ! Rxxjj
            TIMESTEP_MOMENTS(INDEX,26) = TIMESTEP_MOMENTS(INDEX,26) + CX*CY*C2 ! Rxyjj
            TIMESTEP_MOMENTS(INDEX,27) = TIMESTEP_MOMENTS(INDEX,27) + CX*CZ*C2 ! Rxzjj
            TIMESTEP_MOMENTS(INDEX,28) = TIMESTEP_MOMENTS(INDEX,28) + CY*CY*C2 ! Ryyjj
            TIMESTEP_MOMENTS(INDEX,29) = TIMESTEP_MOMENTS(INDEX,29) + CY*CZ*C2 ! Ryzjj
            TIMESTEP_MOMENTS(INDEX,30) = TIMESTEP_MOMENTS(INDEX,30) + CZ*CZ*C2 ! Rzzjj

            TIMESTEP_MOMENTS(INDEX,31) = TIMESTEP_MOMENTS(INDEX,31) + CX*C2*C2 ! Sxiijj
            TIMESTEP_MOMENTS(INDEX,32) = TIMESTEP_MOMENTS(INDEX,32) + CY*C2*C2 ! Syiijj
            TIMESTEP_MOMENTS(INDEX,33) = TIMESTEP_MOMENTS(INDEX,33) + CZ*C2*C2 ! Sziijj

         END DO

         DO JC = 1, NCELLS

            IF (GRID_TYPE == RECTILINEAR_UNIFORM .AND. .NOT. AXI) THEN
               VOL = CELL_VOL
            ELSE
               VOL = CELL_VOLUMES(JC)
            END IF

            IF (BOOL_RADIAL_WEIGHTING) THEN
               CFNUM = CELL_FNUM(particles(JP)%IC)
            ELSE
               CFNUM = FNUM
            END IF

            DO JS = 1, NSPECIES
               INDEX = JC+NCELLS*(JS-1)
               MASS = SPECIES(JS)%MOLECULAR_MASS
               

               ! rho
               TIMESTEP_MOMENTS(INDEX,1) = MASS*CFNUM/VOL*TIMESTEP_NP(INDEX)
               ! Ux, Uy, Uz
               TIMESTEP_MOMENTS(INDEX,2) = TIMESTEP_VX(INDEX)
               TIMESTEP_MOMENTS(INDEX,3) = TIMESTEP_VY(INDEX)
               TIMESTEP_MOMENTS(INDEX,4) = TIMESTEP_VZ(INDEX)
               ! Higher order moments
               TIMESTEP_MOMENTS(INDEX,5:33) = TIMESTEP_MOMENTS(INDEX,5:33)*MASS*CFNUM/VOL
            END DO
         END DO

      END IF


      DO JC = 1, NCELLS
         DO JS = 1, NSPECIES
            INDEX = JC+NCELLS*(JS-1)
            IF (TIMESTEP_NP(INDEX) .GT. 0) THEN


               IF (SPECIES(JS)%ROTDOF .EQ. 0) THEN
                  TIMESTEP_TROT(INDEX) = 0.0
               ELSE
                  TIMESTEP_TROT(INDEX) = 2. / SPECIES(JS)%ROTDOF / KB * (TIMESTEP_EROT(INDEX) / DBLE(TIMESTEP_NP(INDEX)) )
               END IF

               IF (SPECIES(JS)%VIBDOF .EQ. 0) THEN
                  TIMESTEP_TVIB(INDEX) = 0.0
               ELSE
                  TIMESTEP_TVIB(INDEX) = 2. / SPECIES(JS)%VIBDOF / KB * (TIMESTEP_EVIB(INDEX) / DBLE(TIMESTEP_NP(INDEX)) )
               END IF




               IF (TIMESTEP_NP(INDEX) .GT. 1) THEN
                  INTENSIVE_AVERAGE_TWO(INDEX) = .TRUE.
                  NUMPART = DBLE(TIMESTEP_NP(INDEX))
                  ! Old method: SAMPLEDOF = NUMPART. Biased when sample is small.
                  ! This implementation (commented) uses a less biased estimation of the standard deviation.
                  ! SAMPLEDOF = NUMPART - 1.5 + 1./(8*(NUMPART-1))
                  SAMPLEDOF = NUMPART
                  TIMESTEP_TTRX(INDEX) = SPECIES(JS)%MOLECULAR_MASS / KB &
                     * (TIMESTEP_VX2(INDEX) - NUMPART*TIMESTEP_VX(INDEX)*TIMESTEP_VX(INDEX)) / SAMPLEDOF
                  TIMESTEP_TTRY(INDEX) = SPECIES(JS)%MOLECULAR_MASS / KB &
                     * (TIMESTEP_VY2(INDEX) - NUMPART*TIMESTEP_VY(INDEX)*TIMESTEP_VY(INDEX)) / SAMPLEDOF
                  TIMESTEP_TTRZ(INDEX) = SPECIES(JS)%MOLECULAR_MASS / KB &
                     * (TIMESTEP_VZ2(INDEX) - NUMPART*TIMESTEP_VZ(INDEX)*TIMESTEP_VZ(INDEX)) / SAMPLEDOF
               END IF


            END IF
         END DO
      END DO



      ! Collect data from all the processes
      IF (PROC_ID .EQ. 0) THEN
         CALL MPI_REDUCE(MPI_IN_PLACE,  TIMESTEP_NP, NCELLS*NSPECIES, MPI_INTEGER,          MPI_SUM, 0, MPI_COMM_WORLD, ierr)
         CALL MPI_REDUCE(MPI_IN_PLACE,  TIMESTEP_VX,  NCELLS*NSPECIES, MPI_DOUBLE_PRECISION, MPI_SUM, 0, MPI_COMM_WORLD, ierr)
         CALL MPI_REDUCE(MPI_IN_PLACE,  TIMESTEP_VY,  NCELLS*NSPECIES, MPI_DOUBLE_PRECISION, MPI_SUM, 0, MPI_COMM_WORLD, ierr)
         CALL MPI_REDUCE(MPI_IN_PLACE,  TIMESTEP_VZ,  NCELLS*NSPECIES, MPI_DOUBLE_PRECISION, MPI_SUM, 0, MPI_COMM_WORLD, ierr)
         CALL MPI_REDUCE(MPI_IN_PLACE,  TIMESTEP_TTRX,  NCELLS*NSPECIES, MPI_DOUBLE_PRECISION, MPI_SUM, 0, MPI_COMM_WORLD, ierr)
         CALL MPI_REDUCE(MPI_IN_PLACE,  TIMESTEP_TTRY,  NCELLS*NSPECIES, MPI_DOUBLE_PRECISION, MPI_SUM, 0, MPI_COMM_WORLD, ierr)
         CALL MPI_REDUCE(MPI_IN_PLACE,  TIMESTEP_TTRZ,  NCELLS*NSPECIES, MPI_DOUBLE_PRECISION, MPI_SUM, 0, MPI_COMM_WORLD, ierr)
         CALL MPI_REDUCE(MPI_IN_PLACE,  TIMESTEP_TROT,  NCELLS*NSPECIES, MPI_DOUBLE_PRECISION, MPI_SUM, 0, MPI_COMM_WORLD, ierr)
         CALL MPI_REDUCE(MPI_IN_PLACE,  TIMESTEP_TVIB,  NCELLS*NSPECIES, MPI_DOUBLE_PRECISION, MPI_SUM, 0, MPI_COMM_WORLD, ierr)
         CALL MPI_REDUCE(MPI_IN_PLACE,  INTENSIVE_AVERAGE_ONE,  NCELLS*NSPECIES, MPI_LOGICAL, MPI_LOR, 0, MPI_COMM_WORLD, ierr)
         CALL MPI_REDUCE(MPI_IN_PLACE,  INTENSIVE_AVERAGE_TWO,  NCELLS*NSPECIES, MPI_LOGICAL, MPI_LOR, 0, MPI_COMM_WORLD, ierr)
         IF (BOOL_DUMP_MOMENTS) THEN
         CALL MPI_REDUCE(MPI_IN_PLACE,TIMESTEP_MOMENTS,NCELLS*NSPECIES*33,MPI_DOUBLE_PRECISION,MPI_SUM,0,MPI_COMM_WORLD,ierr)
         END IF
         !TALLY = 0
         !DO INDEX = 1, NCELLS*NSPECIES
         !  TALLY = TALLY + TIMESTEP_NP(INDEX)
         !END DO
         !WRITE(*,*) 'Total in postprocess', TALLY
      ELSE
         CALL MPI_REDUCE(TIMESTEP_NP,  TIMESTEP_NP,  NCELLS*NSPECIES, MPI_INTEGER,          MPI_SUM, 0, MPI_COMM_WORLD, ierr)
         CALL MPI_REDUCE(TIMESTEP_VX,   TIMESTEP_VX,   NCELLS*NSPECIES, MPI_DOUBLE_PRECISION, MPI_SUM, 0, MPI_COMM_WORLD, ierr)
         CALL MPI_REDUCE(TIMESTEP_VY,   TIMESTEP_VY,   NCELLS*NSPECIES, MPI_DOUBLE_PRECISION, MPI_SUM, 0, MPI_COMM_WORLD, ierr)
         CALL MPI_REDUCE(TIMESTEP_VZ,   TIMESTEP_VZ,   NCELLS*NSPECIES, MPI_DOUBLE_PRECISION, MPI_SUM, 0, MPI_COMM_WORLD, ierr)
         CALL MPI_REDUCE(TIMESTEP_TTRX,   TIMESTEP_TTRX,   NCELLS*NSPECIES, MPI_DOUBLE_PRECISION, MPI_SUM, 0, MPI_COMM_WORLD, ierr)
         CALL MPI_REDUCE(TIMESTEP_TTRY,   TIMESTEP_TTRY,   NCELLS*NSPECIES, MPI_DOUBLE_PRECISION, MPI_SUM, 0, MPI_COMM_WORLD, ierr)
         CALL MPI_REDUCE(TIMESTEP_TTRZ,   TIMESTEP_TTRZ,   NCELLS*NSPECIES, MPI_DOUBLE_PRECISION, MPI_SUM, 0, MPI_COMM_WORLD, ierr)
         CALL MPI_REDUCE(TIMESTEP_TROT,   TIMESTEP_TROT,   NCELLS*NSPECIES, MPI_DOUBLE_PRECISION, MPI_SUM, 0, MPI_COMM_WORLD, ierr)
         CALL MPI_REDUCE(TIMESTEP_TVIB,   TIMESTEP_TVIB,   NCELLS*NSPECIES, MPI_DOUBLE_PRECISION, MPI_SUM, 0, MPI_COMM_WORLD, ierr)
         CALL MPI_REDUCE(INTENSIVE_AVERAGE_ONE, INTENSIVE_AVERAGE_ONE, NCELLS*NSPECIES, MPI_LOGICAL, MPI_LOR,0,MPI_COMM_WORLD,ierr)
         CALL MPI_REDUCE(INTENSIVE_AVERAGE_TWO, INTENSIVE_AVERAGE_TWO, NCELLS*NSPECIES, MPI_LOGICAL, MPI_LOR,0,MPI_COMM_WORLD,ierr)
         IF (BOOL_DUMP_MOMENTS) THEN
         CALL MPI_REDUCE(TIMESTEP_MOMENTS,TIMESTEP_MOMENTS,NCELLS*NSPECIES*33,MPI_DOUBLE_PRECISION,MPI_SUM,0,MPI_COMM_WORLD,ierr)
         END IF
      END IF

      IF (BOOL_PIC) TIMESTEP_PHI = PHI_FIELD

      ! Add to cumulated average
      DBLE_AVG_CUMULATED = DBLE(AVG_CUMULATED)
      AVG_NP =   (AVG_NP*DBLE_AVG_CUMULATED + DBLE(TIMESTEP_NP))/(AVG_CUMULATED + 1.)
      
      IF (BOOL_PIC) AVG_PHI = (AVG_PHI*DBLE_AVG_CUMULATED + TIMESTEP_PHI)/(AVG_CUMULATED + 1.)

      AVG_CUMULATED = AVG_CUMULATED + 1

      DO INDEX = 1, NCELLS*NSPECIES
         IF (INTENSIVE_AVERAGE_ONE(INDEX)) THEN
         AVG_VX(INDEX) = (AVG_VX(INDEX)*AVG_CUMULATED_INTENSIVE_ONE(INDEX) + TIMESTEP_VX(INDEX)) & 
         /(AVG_CUMULATED_INTENSIVE_ONE(INDEX) + 1.)
         AVG_VY(INDEX) = (AVG_VY(INDEX)*AVG_CUMULATED_INTENSIVE_ONE(INDEX) + TIMESTEP_VY(INDEX)) & 
         /(AVG_CUMULATED_INTENSIVE_ONE(INDEX) + 1.)
         AVG_VZ(INDEX) = (AVG_VZ(INDEX)*AVG_CUMULATED_INTENSIVE_ONE(INDEX) + TIMESTEP_VZ(INDEX)) & 
         /(AVG_CUMULATED_INTENSIVE_ONE(INDEX) + 1.)

         AVG_TROT(INDEX) = (AVG_TROT(INDEX)*AVG_CUMULATED_INTENSIVE_ONE(INDEX) + TIMESTEP_TROT(INDEX)) & 
         /(AVG_CUMULATED_INTENSIVE_ONE(INDEX) + 1.)
         AVG_TVIB(INDEX) = (AVG_TVIB(INDEX)*AVG_CUMULATED_INTENSIVE_ONE(INDEX) + TIMESTEP_TVIB(INDEX)) & 
         /(AVG_CUMULATED_INTENSIVE_ONE(INDEX) + 1.)

         AVG_CUMULATED_INTENSIVE_ONE(INDEX) = AVG_CUMULATED_INTENSIVE_ONE(INDEX) + 1
         END IF
         IF (INTENSIVE_AVERAGE_TWO(INDEX)) THEN
         AVG_TTRX(INDEX) = (AVG_TTRX(INDEX)*AVG_CUMULATED_INTENSIVE_TWO(INDEX) + TIMESTEP_TTRX(INDEX)) &
         /(AVG_CUMULATED_INTENSIVE_TWO(INDEX) + 1.)
         AVG_TTRY(INDEX) = (AVG_TTRY(INDEX)*AVG_CUMULATED_INTENSIVE_TWO(INDEX) + TIMESTEP_TTRY(INDEX)) &
         /(AVG_CUMULATED_INTENSIVE_TWO(INDEX) + 1.)
         AVG_TTRZ(INDEX) = (AVG_TTRZ(INDEX)*AVG_CUMULATED_INTENSIVE_TWO(INDEX) + TIMESTEP_TTRZ(INDEX)) &
         /(AVG_CUMULATED_INTENSIVE_TWO(INDEX) + 1.)

         IF (BOOL_DUMP_MOMENTS) THEN
            AVG_MOMENTS(INDEX,:) = (AVG_MOMENTS(INDEX,:)*AVG_CUMULATED_INTENSIVE_TWO(INDEX) + TIMESTEP_MOMENTS(INDEX,:)) &
            /(AVG_CUMULATED_INTENSIVE_TWO(INDEX) + 1.)
         END IF

         AVG_CUMULATED_INTENSIVE_TWO(INDEX) = AVG_CUMULATED_INTENSIVE_TWO(INDEX) + 1
         END IF
      END DO

      AVG_TTR = (AVG_TTRX + AVG_TTRY + AVG_TTRZ) / 3.0



         
      DEALLOCATE(TIMESTEP_NP)
      
      DEALLOCATE(TIMESTEP_N)

      DEALLOCATE(TIMESTEP_VX)
      DEALLOCATE(TIMESTEP_VY)
      DEALLOCATE(TIMESTEP_VZ)

      DEALLOCATE(TIMESTEP_VX2)
      DEALLOCATE(TIMESTEP_VY2)
      DEALLOCATE(TIMESTEP_VZ2)
      
      DEALLOCATE(TIMESTEP_TTRX)
      DEALLOCATE(TIMESTEP_TTRY)
      DEALLOCATE(TIMESTEP_TTRZ)
      DEALLOCATE(TIMESTEP_TTR)
      
      DEALLOCATE(TIMESTEP_EROT)
      DEALLOCATE(TIMESTEP_EVIB)

      DEALLOCATE(TIMESTEP_TROT)
      DEALLOCATE(TIMESTEP_TVIB)

      DEALLOCATE(INTENSIVE_AVERAGE_ONE)
      DEALLOCATE(INTENSIVE_AVERAGE_TWO)

      IF (BOOL_DUMP_MOMENTS) DEALLOCATE(TIMESTEP_MOMENTS)

      IF (BOOL_PIC) DEALLOCATE(TIMESTEP_PHI)
      
   END SUBROUTINE GRID_AVG



   !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
   ! SUBROUTINE GRID_SAVE -> Saves cumulated average !!!!!!!!!!!!!!!!!!!!
   !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!


   SUBROUTINE GRID_SAVE
         
      IMPLICIT NONE

      CHARACTER*256                      :: string, file_name
      CHARACTER*7, DIMENSION(33)         :: MOMENT_STRING 

      REAL(KIND=8), DIMENSION(NX+1)      :: XNODES
      REAL(KIND=8), DIMENSION(NY+1)      :: YNODES


      INTEGER                            :: NCELLS, NSPECIES
      INTEGER                            :: i, JS, FIRST, LAST, JPROC, MOM

      INTEGER, DIMENSION(:), ALLOCATABLE :: CELL_PROC_ID


      MOMENT_STRING = ['rho_   ', &
                        'Ux_    ', 'Uy_    ', 'Uz_    ', &
                        'Pxx_   ', 'Pxy_   ', 'Pxz_   ', 'Pyy_   ', 'Pyz_   ', 'Pzz_   ', &
                        'qx_    ', 'qy_    ', 'qz_    ', &
                        'Qxxx_  ', 'Qxxy_  ', 'Qxyy_  ', 'Qyyy_  ', 'Qyyz_  ', &
                        'Qyzz_  ', 'Qzzz_  ', 'Qxxz_  ', 'Qxzz_  ', 'Qxyz_  ', &
                        'Riijj_ ', 'Rxxjj_ ', 'Rxyjj_ ', 'Rxzjj_ ', 'Ryyjj_ ', 'Ryzjj_ ', 'Rzzjj_ ', &
                        'Sxiijj_', 'Syiijj_', 'Sziijj_']

      NCELLS = NX*NY
      NSPECIES = N_SPECIES

      IF (PROC_ID .EQ. 0) THEN
         IF (GRID_TYPE == RECTILINEAR_UNIFORM) THEN
            XNODES = 0
            DO i = 0, NX
               XNODES(i+1) = XMIN + (XMAX-XMIN)/NX*i 
            END DO

            YNODES = 0
            DO i = 0, NY
               YNODES(i+1) = YMIN + (YMAX-YMIN)/NY*i
            END DO
         ELSE IF (GRID_TYPE == RECTILINEAR_NONUNIFORM) THEN
            XNODES = XCOORD
            YNODES = YCOORD
         END IF

         ALLOCATE(CELL_PROC_ID(NCELLS))
         DO i = 0, NCELLS
            CALL PROC_FROM_CELL(i, JPROC)
            CELL_PROC_ID(i) = JPROC
         END DO

         ! DSMC flowfield file

         !WRITE(file_name,'(A, I0, A)') '/media/pietro/Storage/panteradumps/dsmc_flowfield_', tID, '.vtk'
         WRITE(file_name,'(A, A, I0, A)') TRIM(ADJUSTL(FLOWFIELD_SAVE_PATH)), 'dsmc_flowfield_', tID, '.vtk'

         OPEN(54321, FILE=file_name, ACCESS='SEQUENTIAL', FORM='formatted', STATUS='new')

         WRITE(54321,'(A)') '# vtk DataFile Version 3.0'
         WRITE(54321,'(A)') 'vtk output'
         WRITE(54321,'(A)') 'ASCII'
         WRITE(54321,'(A)') 'DATASET RECTILINEAR_GRID'
         WRITE(54321,'(A,I10,I10,I10)') 'DIMENSIONS', NX+1, NY+1, 1 

         WRITE(54321,'(A,I10,A7)') 'X_COORDINATES', NX+1, 'double'
         WRITE(54321,*) XNODES

         WRITE(54321,'(A,I10,A7)') 'Y_COORDINATES', NY+1, 'double'
         WRITE(54321,*) YNODES

         WRITE(54321,'(A,I10,A7)') 'Z_COORDINATES', 1, 'double'
         WRITE(54321,*) 0.

         WRITE(54321,'(A,I10)') 'CELL_DATA', NCELLS
         IF (BOOL_DUMP_MOMENTS) THEN
            WRITE(54321,'(A,I10)') 'FIELD FieldData', (13+33)*NSPECIES+1
         ELSE
            WRITE(54321,'(A,I10)') 'FIELD FieldData', 13*NSPECIES+1
         END IF


         ! Write per-cell value
         WRITE(54321,'(A,I10,I10,A8)') 'PROC_ID', 1, NCELLS, 'integer'
         WRITE(54321,*) CELL_PROC_ID

         ! Write per-cell, per-species values
         DO JS = 1, NSPECIES
            FIRST = 1 + (JS-1)*NCELLS
            LAST  = JS*NCELLS
            
            WRITE(string, *) 'number_particles_', SPECIES(JS)%NAME
            WRITE(54321,'(A,I10,I10,A7)') string, 1, NCELLS, 'double'
            WRITE(54321,*) AVG_NP(FIRST:LAST)

            WRITE(string, *) 'nrho_mean_', SPECIES(JS)%NAME
            WRITE(54321,'(A,I10,I10,A7)') string, 1, NCELLS, 'double'
            IF (GRID_TYPE == RECTILINEAR_NONUNIFORM .OR. AXI) THEN
               IF (BOOL_RADIAL_WEIGHTING) THEN
                  WRITE(54321,*) CELL_FNUM*AVG_NP(FIRST:LAST)/CELL_VOLUMES
               ELSE
                  WRITE(54321,*) FNUM*AVG_NP(FIRST:LAST)/CELL_VOLUMES
               END IF
            ELSE IF (GRID_TYPE == RECTILINEAR_UNIFORM) THEN
               WRITE(54321,*) FNUM*AVG_NP(FIRST:LAST)/CELL_VOL
            END IF

            WRITE(string, *) 'vx_mean_', SPECIES(JS)%NAME
            WRITE(54321,'(A,I10,I10,A7)') string, 1, NCELLS, 'double'
            WRITE(54321,*) AVG_VX(FIRST:LAST)

            WRITE(string, *) 'vy_mean_', SPECIES(JS)%NAME
            WRITE(54321,'(A,I10,I10,A7)') string, 1, NCELLS, 'double'
            WRITE(54321,*) AVG_VY(FIRST:LAST)

            WRITE(string, *) 'vz_mean_', SPECIES(JS)%NAME
            WRITE(54321,'(A,I10,I10,A7)') string, 1, NCELLS, 'double'
            WRITE(54321,*) AVG_VZ(FIRST:LAST)

            WRITE(string, *) 'Ttrx_mean_', SPECIES(JS)%NAME
            WRITE(54321,'(A,I10,I10,A7)') string, 1, NCELLS, 'double'
            WRITE(54321,*) AVG_TTRX(FIRST:LAST)

            WRITE(string, *) 'Ttry_mean_', SPECIES(JS)%NAME
            WRITE(54321,'(A,I10,I10,A7)') string, 1, NCELLS, 'double'
            WRITE(54321,*) AVG_TTRY(FIRST:LAST)

            WRITE(string, *) 'Ttrz_mean_', SPECIES(JS)%NAME
            WRITE(54321,'(A,I10,I10,A7)') string, 1, NCELLS, 'double'
            WRITE(54321,*) AVG_TTRZ(FIRST:LAST)

            WRITE(string, *) 'Ttr_mean_', SPECIES(JS)%NAME
            WRITE(54321,'(A,I10,I10,A7)') string, 1, NCELLS, 'double'
            WRITE(54321,*) AVG_TTR(FIRST:LAST)

            WRITE(string, *) 'Trot_mean_', SPECIES(JS)%NAME
            WRITE(54321,'(A,I10,I10,A7)') string, 1, NCELLS, 'double'
            WRITE(54321,*) AVG_TROT(FIRST:LAST)

            WRITE(string, *) 'Tvib_mean_', SPECIES(JS)%NAME
            WRITE(54321,'(A,I10,I10,A7)') string, 1, NCELLS, 'double'
            WRITE(54321,*) AVG_TVIB(FIRST:LAST)

            WRITE(string, *) 'num_cumulated_one_', SPECIES(JS)%NAME
            WRITE(54321,'(A,I10,I10,A8)') string, 1, NCELLS, 'integer'
            WRITE(54321,*) AVG_CUMULATED_INTENSIVE_ONE(FIRST:LAST)

            WRITE(string, *) 'num_cumulated_two_', SPECIES(JS)%NAME
            WRITE(54321,'(A,I10,I10,A8)') string, 1, NCELLS, 'integer'
            WRITE(54321,*) AVG_CUMULATED_INTENSIVE_TWO(FIRST:LAST)

            
            IF (BOOL_DUMP_MOMENTS) THEN
               ! Now dump the 33 moments
               DO MOM = 1, 33
                  WRITE(54321,'(A,A,I10,I10,A7)') TRIM(MOMENT_STRING(MOM)), SPECIES(JS)%NAME, 1, NCELLS, 'double'
                  WRITE(54321,*) AVG_MOMENTS(FIRST:LAST, MOM)
               END DO
            END IF
         
         
         END DO

         IF (BOOL_PIC) THEN
            IF (DIMS == 2) THEN
               WRITE(54321,'(A,I10)') 'POINT_DATA', (NX+1)*(NY+1)*1
               WRITE(54321,'(A,I10)') 'FIELD FieldData', 5
               
               WRITE(54321,'(A,I10,I10,A7)') 'QRHO', 1, (NX+1)*(NY+1)*1, 'double'
               WRITE(54321,*) Q_FIELD

               WRITE(54321,'(A,I10,I10,A7)') 'PHI', 1, (NX+1)*(NY+1)*1, 'double'
               WRITE(54321,*) AVG_PHI

               WRITE(54321,'(A,I10,I10,A7)') 'E_X', 1, (NX+1)*(NY+1)*1, 'double'
               WRITE(54321,*) E_FIELD(:,:,1)

               WRITE(54321,'(A,I10,I10,A7)') 'E_Y', 1, (NX+1)*(NY+1)*1, 'double'
               WRITE(54321,*) E_FIELD(:,:,2)

               WRITE(54321,'(A,I10,I10,A7)') 'E_Z', 1, (NX+1)*(NY+1)*1, 'double'
               WRITE(54321,*) E_FIELD(:,:,3)
            ELSE
               WRITE(54321,'(A,I10)') 'POINT_DATA', (NX+1)*(NY+1)*1
               WRITE(54321,'(A,I10)') 'FIELD FieldData', 5
               
               WRITE(54321,'(A,I10,I10,A7)') 'QRHO', 1, (NX+1)*(NY+1)*1, 'double'
               WRITE(54321,*) Q_FIELD, Q_FIELD

               WRITE(54321,'(A,I10,I10,A7)') 'PHI', 1, (NX+1)*(NY+1)*1, 'double'
               WRITE(54321,*) PHI_FIELD, PHI_FIELD

               WRITE(54321,'(A,I10,I10,A7)') 'E_X', 1, (NX+1)*(NY+1)*1, 'double'
               WRITE(54321,*) E_FIELD(:,:,1), E_FIELD(:,:,1)

               WRITE(54321,'(A,I10,I10,A7)') 'E_Y', 1, (NX+1)*(NY+1)*1, 'double'
               WRITE(54321,*) E_FIELD(:,:,2), E_FIELD(:,:,2)

               WRITE(54321,'(A,I10,I10,A7)') 'E_Z', 1, (NX+1)*(NY+1)*1, 'double'
               WRITE(54321,*) E_FIELD(:,:,3), E_FIELD(:,:,3)
            END IF
         END IF

         CLOSE(54321)

      END IF 

   END SUBROUTINE GRID_SAVE


   SUBROUTINE INIT_POSTPROCESS

      IMPLICIT NONE

      INTEGER :: LENGTH

      LENGTH = NX*NY * N_SPECIES
      
      ALLOCATE(AVG_NP(LENGTH))
      
      ALLOCATE(AVG_N(LENGTH))

      ALLOCATE(AVG_VX(LENGTH))
      ALLOCATE(AVG_VY(LENGTH))
      ALLOCATE(AVG_VZ(LENGTH))
      
      ALLOCATE(AVG_TTRX(LENGTH))
      ALLOCATE(AVG_TTRY(LENGTH))
      ALLOCATE(AVG_TTRZ(LENGTH))
      ALLOCATE(AVG_TTR(LENGTH))

      ALLOCATE(AVG_TROT(LENGTH))
      ALLOCATE(AVG_TVIB(LENGTH))
      
      ALLOCATE(AVG_CUMULATED_INTENSIVE_ONE(LENGTH))
      ALLOCATE(AVG_CUMULATED_INTENSIVE_TWO(LENGTH))

      AVG_NP = 0

      AVG_N = 0

      AVG_VX = 0
      AVG_VY = 0
      AVG_VZ = 0

      AVG_TTRX = 0
      AVG_TTRY = 0
      AVG_TTRZ = 0
      AVG_TTR = 0

      AVG_TROT = 0
      AVG_TVIB = 0


      AVG_CUMULATED = 0
      AVG_CUMULATED_INTENSIVE_ONE = 0
      AVG_CUMULATED_INTENSIVE_TWO = 0

      IF (BOOL_DUMP_MOMENTS) THEN
         ALLOCATE(AVG_MOMENTS(LENGTH,33))
         AVG_MOMENTS = 0
      END IF

      IF (BOOL_PIC) THEN
         ALLOCATE(AVG_PHI(NPX, NPY))
         AVG_PHI = 0
      END IF

      

   END SUBROUTINE INIT_POSTPROCESS

   !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
   ! SUBROUTINE GRID_RESET -> Resets cumulated average !!!!!!!!!!!!!!!!!!
   !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!

   SUBROUTINE GRID_RESET

      IMPLICIT NONE

      AVG_NP = 0

      AVG_N = 0

      AVG_VX = 0
      AVG_VY = 0
      AVG_VZ = 0

      AVG_TTRX = 0
      AVG_TTRY = 0
      AVG_TTRZ = 0
      AVG_TTR = 0

      AVG_TROT = 0
      AVG_TVIB = 0

      AVG_CUMULATED = 0
      AVG_CUMULATED_INTENSIVE_ONE = 0
      AVG_CUMULATED_INTENSIVE_TWO = 0

      IF (BOOL_DUMP_MOMENTS) AVG_MOMENTS = 0

   END SUBROUTINE GRID_RESET


   SUBROUTINE CHECKS

      IMPLICIT NONE

      INTEGER                            :: JP, JS
   
      INTEGER                            :: TOT_NUM

      REAL(KIND=8), DIMENSION(3)         :: TOT_MOMENTUM
      REAL(KIND=8)                       :: TOT_KE, TOT_IE, TOT_FE, TOT_EE, HX, HY, PHI, CURRENT_TIME
      REAL(KIND=8)                       :: CFNUM

      TOT_NUM = 0
      TOT_MOMENTUM = 0
      TOT_KE = 0
      TOT_IE = 0
      TOT_FE = 0
      TOT_EE = 0

      CURRENT_TIME = tID*DT

      ! Number of particles
      DO JP = 1, NP_PROC
         TOT_NUM = TOT_NUM + 1

         JS = particles(JP)%S_ID

         IF (BOOL_RADIAL_WEIGHTING) THEN
            CFNUM = CELL_FNUM(particles(JP)%IC)
         ELSE
            CFNUM = FNUM
         END IF

         ! Momentum
         TOT_MOMENTUM(1) = TOT_MOMENTUM(1) + SPECIES(JS)%MOLECULAR_MASS*particles(JP)%VX* CFNUM
         TOT_MOMENTUM(2) = TOT_MOMENTUM(2) + SPECIES(JS)%MOLECULAR_MASS*particles(JP)%VY* CFNUM
         TOT_MOMENTUM(3) = TOT_MOMENTUM(3) + SPECIES(JS)%MOLECULAR_MASS*particles(JP)%VZ* CFNUM
         

         ! Kinietic energy
         TOT_KE = TOT_KE + 0.5*SPECIES(JS)%MOLECULAR_MASS*(particles(JP)%VX**2+particles(JP)%VY**2+particles(JP)%VZ**2) &
                  * CFNUM
         TOT_IE = TOT_IE + (particles(JP)%EROT + particles(JP)%EVIB) * CFNUM

         !IF (JS == 4) THEN
         !  TOT_FE = TOT_FE + 15.63e-19/2.
         !END IF
         IF (BOOL_PIC) THEN
            CALL APPLY_POTENTIAL(JP, PHI)
            TOT_EE  = TOT_EE + PHI*1.602176634e-19*SPECIES(JS)%CHARGE * CFNUM
         END IF

      END DO


      ! Collect data from all the processes and print it
      IF (PROC_ID .EQ. 0) THEN
         CALL MPI_REDUCE(MPI_IN_PLACE,  TOT_NUM,      1, MPI_INTEGER,          MPI_SUM, 0, MPI_COMM_WORLD, ierr)
         CALL MPI_REDUCE(MPI_IN_PLACE,  TOT_MOMENTUM, 3, MPI_DOUBLE_PRECISION, MPI_SUM, 0, MPI_COMM_WORLD, ierr)
         CALL MPI_REDUCE(MPI_IN_PLACE,  TOT_KE,       1, MPI_DOUBLE_PRECISION, MPI_SUM, 0, MPI_COMM_WORLD, ierr)
         CALL MPI_REDUCE(MPI_IN_PLACE,  TOT_IE,       1, MPI_DOUBLE_PRECISION, MPI_SUM, 0, MPI_COMM_WORLD, ierr)
         CALL MPI_REDUCE(MPI_IN_PLACE,  TOT_EE,       1, MPI_DOUBLE_PRECISION, MPI_SUM, 0, MPI_COMM_WORLD, ierr)
         !CALL MPI_REDUCE(MPI_IN_PLACE,  TOT_FE,       1, MPI_DOUBLE_PRECISION, MPI_SUM, 0, MPI_COMM_WORLD, ierr)

         HX = (XMAX-XMIN)/DBLE(NX)
         HY = (YMAX-YMIN)/DBLE(NY)
         !TOT_EE = -HX*HY*8.8541878128E-12*SUM( Q_FIELD*PACK(PHI_FIELD, .TRUE.) )/FNUM

         ! WRITE(*,*) ' '
         ! WRITE(*,*) 'Conservation checks:'
         ! WRITE(*,*) 'Number of particles:  ', TOT_NUM
         ! WRITE(*,*) 'Total momentum:       [ ', TOT_MOMENTUM, ' ] [kg m/s]'
         ! WRITE(*,*) 'Total kinetic energy:   ', TOT_KE, ' [J]'
         ! WRITE(*,*) 'Total internal energy:  ', TOT_IE, ' [J]'
         ! WRITE(*,*) 'Total formation energy: ', TOT_FE, ' [J]'
         ! WRITE(*,*) 'Total electrostatic energy: ', TOT_EE, ' [J]'
         ! WRITE(*,*) 'Total energy:          ', TOT_KE+TOT_IE+TOT_FE+TOT_EE, ' [J]'
         ! WRITE(*,*) ' '

         OPEN(54331, FILE='conservation_checks', POSITION='append', STATUS='unknown', ACTION='write')
         WRITE(54331,*) CURRENT_TIME, TOT_NUM, TOT_MOMENTUM, TOT_KE, TOT_IE, TOT_EE !TOT_FE, TOT_EE
         CLOSE(54331)

      ELSE
         CALL MPI_REDUCE(TOT_NUM,       TOT_NUM,      1, MPI_INTEGER,          MPI_SUM, 0, MPI_COMM_WORLD, ierr)
         CALL MPI_REDUCE(TOT_MOMENTUM,  TOT_MOMENTUM, 3, MPI_DOUBLE_PRECISION, MPI_SUM, 0, MPI_COMM_WORLD, ierr)
         CALL MPI_REDUCE(TOT_KE,        TOT_KE,       1, MPI_DOUBLE_PRECISION, MPI_SUM, 0, MPI_COMM_WORLD, ierr)
         CALL MPI_REDUCE(TOT_IE,        TOT_IE,       1, MPI_DOUBLE_PRECISION, MPI_SUM, 0, MPI_COMM_WORLD, ierr)
         CALL MPI_REDUCE(TOT_EE,        TOT_EE,       1, MPI_DOUBLE_PRECISION, MPI_SUM, 0, MPI_COMM_WORLD, ierr)
         !CALL MPI_REDUCE(TOT_FE,        TOT_FE,       1, MPI_DOUBLE_PRECISION, MPI_SUM, 0, MPI_COMM_WORLD, ierr)
      END IF

   END SUBROUTINE CHECKS

END MODULE postprocess